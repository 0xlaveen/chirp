import AppKit
import ChirpCore
import ChirpUI

/// Glue between the pure state machine and the system: capture, socket, HUD, insertion.
@MainActor
final class DictationController {
    private(set) var machine = DictationMachine()
    private(set) var health: Health?
    private(set) var healthError: String?
    var onChange: (() -> Void)?
    /// Called on every press of the dictation hotkey (the setup window's "Try it" step listens for it).
    var onHotkeyPressed: (() -> Void)?

    let hud = HUDController()
    private let capture = AudioCapture(engine: SystemCaptureEngine(pickedDevice: { InputDevice.pickedID(uid: settings.inputDeviceUID) }))
    private let inserter = TextInserter(env: SystemInsertion.environment(), pasteboard: SystemPasteboard())

    private var session: StreamSession?
    private var eventTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var epoch = 0
    private var pendingFinal: FinalResult?
    /// The raw transcript from `correcting`: what is inserted if clean-up fails. Never logged; cleared on every exit.
    private var polishingRaw: String?
    /// "Insert raw immediately": the raw insertion started when `correcting` arrived (nil outcome: cancelled first).
    private var rawInsertTask: Task<InsertionOutcome?, Never>?
    private var startOptions = StartOptions()

    /// Longer than the server's own clean-up timeout (8 s by default), so the server's fallback normally wins.
    static let correctionTimeout: Duration = .seconds(12)
    private static let cancellable: [DictationState] = [.connecting, .listening, .finalizing, .correcting]

    static let dictateID: UInt32 = 1
    private static let escapeID: UInt32 = 2

    /// (Re)registers the dictation hotkey from settings.
    @discardableResult
    func registerHotkey() -> Bool {
        HotKeyCenter.shared.register(id: Self.dictateID, combo: settings.hotkey,
                                     onDown: { [weak self] in self?.hotkeyDown() },
                                     onUp: { [weak self] in self?.hotkeyUp() })
    }

    /// Releases the dictation hotkey while the shortcut recorder listens; `registerHotkey()` takes it back.
    func suspendHotkey() { HotKeyCenter.shared.unregister(id: Self.dictateID) }

    var state: DictationState { machine.state }
    var debugRetention: Bool { hud.model.debugRetention || (health?.debugRetention ?? false) }

    // MARK: input from the hotkeys

    func hotkeyDown() {
        onHotkeyPressed?()
        send(.hotkeyDown(at: ProcessInfo.processInfo.systemUptime))
    }
    func hotkeyUp() { send(.hotkeyUp(at: ProcessInfo.processInfo.systemUptime)) }
    func escape() { send(.escape) }

    /// "Start/Stop dictation" in the menu: a tap of the hotkey, so it starts a toggle-mode dictation or ends one.
    func toggleDictation() {
        let now = ProcessInfo.processInfo.systemUptime
        send(.hotkeyDown(at: now))
        send(.hotkeyUp(at: now))
    }

    // MARK: health

    func refreshHealth() async {
        let config = settings.serverConfig()
        do {
            health = try await config.fetchHealth()
            healthError = nil
        } catch {
            health = nil
            healthError = "Server unreachable at \(config.host)"
        }
        onChange?()
    }

    // MARK: state machine plumbing

    private func send(_ event: DictationEvent) {
        let before = machine.state
        let effects = machine.handle(event)
        if machine.state != before {

            chirpLog.info("state \(String(describing: before), privacy: .public) -> \(String(describing: self.machine.state), privacy: .public)")
            // Esc is only claimed while a dictation is active, so it is untouched the rest of the time.
            if Self.cancellable.contains(machine.state) {
                HotKeyCenter.shared.register(id: Self.escapeID, combo: .escape) { [weak self] in self?.escape() }
            } else {
                HotKeyCenter.shared.unregister(id: Self.escapeID)
            }
            renderStatus()
            onChange?()
        }
        for effect in effects { run(effect) }
        // After the effects: the stop cue plays once capture has ended, and the start cue before the mic opens (see begin).
        if let cue = SoundCue.cue(from: before, to: machine.state, enabled: settings.soundsEnabled) { Sounds.play(cue) }
    }

    private func renderStatus() {
        switch machine.state {
        case .idle, .inserting: break
        case .connecting: hud.model.status = HUDStatus.connecting
        case .listening: hud.model.status = HUDStatus.listening; hud.announce(HUDStatus.listening)
        case .finalizing: hud.model.status = HUDStatus.finishing
        case .correcting: hud.model.status = HUDStatus.polishing; hud.model.indicator = .sparkle
        case .error(let m): hud.model.status = m; hud.model.isError = true; hud.model.indicator = .warning
        }
    }

    private func run(_ effect: DictationEffect) {
        switch effect {
        case .start: begin()
        case .finalize: finalize()
        case .cancel: teardown(cancelServer: true); hud.hide(); inserter.forgetUndo()
        case .abort(let message):
            teardown(cancelServer: true)
            inserter.forgetUndo()
            hud.model.status = message
            hud.model.isError = true
            hud.model.indicator = .warning
            hud.model.silence()
            hud.show()
            hud.announce(message)
            hud.hide(after: 3.5)
        case .insert: insert()
        }
    }

    private func begin() {
        epoch += 1
        let myEpoch = epoch
        pendingFinal = nil
        polishingRaw = nil
        rawInsertTask = nil
        inserter.forgetUndo()
        hud.cancelHide()
        hud.model.reset()
        hud.model.status = HUDStatus.connecting
        hud.model.debugRetention = health?.debugRetention ?? false
        // The frontmost app picks the style now, before the HUD or any permission prompt can change focus.
        startOptions = settings.startOptions(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                             available: health?.correctionProfiles)
        hud.model.styleName = startOptions.correction ? CorrectionProfile.name(for: startOptions.correctionProfile, in: health) : nil
        hud.show()
        // The start cue plays right after this (see `send`); the microphone must not open before it is over.
        let micMayOpen = ContinuousClock.now + .seconds(Sounds.startDelay())

        Task {
            chirpLog.info("microphone authorization=\(Permissions.microphone.rawValue, privacy: .public) accessibility=\(Permissions.accessibilityGranted, privacy: .public)")
            guard await Permissions.requestMicrophone() else {
                if epoch == myEpoch, machine.state.isActive {
                    Permissions.openSettings(.microphone)
                    send(.failed("Microphone access denied — enable it in System Settings"))
                }
                return
            }
            // Let the start cue finish before the microphone opens, so it is never part of the recording:
            // min(cue length + 20 ms, 300 ms), counted from when the cue started (a permission wait counts too).
            try? await Task.sleep(until: micMayOpen, clock: .continuous)
            guard epoch == myEpoch, machine.state == .connecting || machine.state == .listening else { return }
            startStreaming(epoch: myEpoch)
        }
    }

    private func startStreaming(epoch myEpoch: Int) {
        let session = StreamSession(config: settings.serverConfig(), options: startOptions)
        self.session = session
        let sink = CaptureSink(session: session) { [weak self] level in
            Task { @MainActor in
                guard let self, self.epoch == myEpoch else { return }
                self.hud.model.pushLevel(level.rms)
            }
        } onSilence: { [weak self] in
            Task { @MainActor in
                guard let self, self.epoch == myEpoch, self.machine.state.isActive else { return }
                self.send(.failed("No microphone signal"))
            }
        }
        do {
            try capture.start(onFailure: { [weak self] in
                Task { @MainActor in
                    guard let self, self.epoch == myEpoch, self.machine.state.isActive else { return }
                    self.send(.failed("The microphone stopped — check the input device"))
                }
            }) { sink.handle($0) }
        } catch {
            send(.failed(error is CaptureError ? "No microphone input device" : "Could not start the microphone"))
            return
        }
        eventTask = Task { [weak self] in
            await session.open()
            for await event in session.events {
                guard let self, self.epoch == myEpoch else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: StreamEvent) {
        switch event {
        case .message(.ready(_, _, let debug)):
            hud.model.debugRetention = debug
            send(.serverReady)
        case .message(.partial(_, let text, let stable)):
            guard [.connecting, .listening, .finalizing].contains(machine.state) else { return }
            let (s, u) = splitPartial(text: text, stable: stable)
            hud.model.stable = s
            hud.model.unstable = u
        case .message(.correcting(_, let raw, let profile)):
            guard machine.state == .finalizing else { return }
            beginPolishing(raw: raw, profile: profile)
        case .message(.final(let f)):
            pendingFinal = f
            send(.finalReceived)
        case .message(.error(let code, let message)):
            if machine.state == .correcting { failCorrection(); return }
            send(.failed(Self.friendly(code: code, message: message)))
        case .message(.unknown): break
        case .closed(let reason):
            if machine.state == .correcting { failCorrection(); return }
            if [.connecting, .listening, .finalizing].contains(machine.state) {
                send(.failed(reason ?? "Connection closed"))
            }
        }
    }

    /// `correcting` arrived: show the raw transcript at once, solid, with the polishing state and the style chip.
    private func beginPolishing(raw: String, profile: String) {
        polishingRaw = raw
        hud.model.beginPolishing(raw: raw, style: CorrectionProfile.name(for: profile, in: health))
        send(.correctingReceived)
        hud.announce(HUDStatus.polishing)
        let myEpoch = epoch
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.correctionTimeout)
            guard !Task.isCancelled, let self, self.epoch == myEpoch, self.machine.state == .correcting else { return }
            self.failCorrection()
        }
        // "Insert raw immediately": only where the AX write can be replaced in place later; elsewhere the cleaned
        // text is inserted once, as usual.
        if settings.insertRawFirst, inserter.canReplaceInPlace() {
            rawInsertTask = Task { [weak self] in
                guard let self, self.epoch == myEpoch, self.machine.state == .correcting else { return nil }
                return await self.inserter.insert(raw, undoRaw: raw, undoWindow: TextInserter.swapWindow)
            }
        }
    }

    /// Clean-up timed out, errored or lost its socket: keep the raw transcript.
    private func failCorrection() {
        guard machine.state == .correcting else { return }
        pendingFinal = FinalResult(text: polishingRaw ?? "", corrected: false, correctionError: "timeout")
        send(.correctionFailed)
    }

    private static func friendly(code: String, message: String) -> String {
        switch code {
        case "auth": "Server rejected the token (check ~/.config/chirp/token)"
        case "busy": "Server is busy — try again"
        case "too_long": "Utterance too long"
        default: message
        }
    }

    private func finalize() {
        stopCapture()
        hud.model.silence()
        let session = self.session, myEpoch = epoch
        Task { await session?.stop() }
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let self, self.epoch == myEpoch, self.machine.state == .finalizing else { return }
            self.send(.failed("Timed out waiting for the transcript"))
        }
    }

    private func stopCapture() { capture.stop() }

    private func teardown(cancelServer: Bool) {
        epoch += 1   // invalidates every in-flight callback of the old session
        pendingFinal = nil
        polishingRaw = nil
        rawInsertTask = nil
        timeoutTask?.cancel()
        stopCapture()
        eventTask?.cancel()
        eventTask = nil
        if let s = session {
            Task { cancelServer ? await s.cancel() : await s.close() }
        }
        session = nil
    }

    // MARK: insertion

    private func insert() {
        timeoutTask?.cancel()
        // Consume the final: nothing but the inserter's short-lived undo state may outlive this insertion.
        guard let final = pendingFinal else { send(.insertionFinished); return }
        pendingFinal = nil
        polishingRaw = nil
        let rawFirst = rawInsertTask
        rawInsertTask = nil
        let text = final.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = session
        session = nil
        eventTask?.cancel(); eventTask = nil
        Task { await s?.close() }
        guard !text.isEmpty else {
            hud.model.polishing = false
            hud.model.diff = nil
            hud.model.stable = ""
            hud.model.unstable = ""
            hud.model.status = HUDStatus.noSpeech
            hud.model.indicator = .none
            hud.announce(HUDStatus.noSpeech)
            hud.model.silence()
            hud.hide(after: 1.5)
            send(.insertionFinished)
            return
        }
        Task {
            if let rawFirst, let early = await rawFirst.value {
                await replaceRaw(early, with: final, text: text)
            } else {
                // The cleaned text is shown with its changes highlighted before it is inserted, once.
                if final.canUseRaw { await hud.model.playChangeHighlight(raw: final.raw, cleaned: text) }
                else { hud.model.settle(on: text) }
                hud.model.status = HUDStatus.inserting
                hud.model.indicator = .waveform
                let outcome = await inserter.insert(text, undoRaw: final.canUseRaw && settings.showRawAfterCleanup ? final.raw : nil)
                show(outcome, final: final)
            }
            send(.insertionFinished)
        }
    }

    /// "Insert raw immediately" finished its raw insertion earlier; swap in the cleaned text when the AX insert was
    /// verified and the range still holds it, otherwise leave the raw text where it is.
    private func replaceRaw(_ early: InsertionOutcome, with final: FinalResult, text: String) async {
        var shown = final
        if early == .inserted(.ax), final.canUseRaw {
            await hud.model.playChangeHighlight(raw: final.raw, cleaned: text)
            if await inserter.replaceInserted(with: text) {
                show(early, final: final)
                return
            }
            hud.model.settle(on: final.raw)
            shown = FinalResult(text: final.raw, corrected: false, correctionError: "replace")
        } else {
            inserter.forgetUndo()
            hud.model.settle(on: final.raw)
            if final.canUseRaw { shown = FinalResult(text: final.raw, corrected: false, correctionError: "replace") }
            else { shown.text = final.raw }
        }
        show(early, final: shown)
    }

    private func show(_ outcome: InsertionOutcome, final: FinalResult) {
        let p = OutcomePresentation.of(outcome, final: final, offerRaw: settings.showRawAfterCleanup)
        hud.model.status = p.status
        hud.model.indicator = p.indicator
        hud.model.cleaned = p.cleaned
        hud.model.keptOriginal = p.keptOriginal
        hud.model.isError = p.isError
        hud.model.showUseRaw = p.showUseRaw
        hud.model.onUseRaw = p.showUseRaw ? { [weak self] in self?.useRaw() } : nil
        hud.show()
        hud.hide(after: p.linger)
        hud.announce(p.status)
    }

    /// Replace the inserted correction with the raw transcript, in place for a verified AX insertion and otherwise
    /// by copying it; the inserter refuses once the undo window has expired or the target changed.
    private func useRaw() {
        guard !machine.state.isActive else { return }
        hud.model.showUseRaw = false
        hud.model.cleaned = false
        hud.model.stable = ""
        Task {
            guard let outcome = await inserter.useRaw() else { return }
            hud.model.isError = outcome == .refusedSecure
            switch outcome {
            case .inserted: hud.model.status = "Inserted raw"; hud.model.indicator = .success
            case .refusedSecure: hud.model.status = "Secure field — unchanged"; hud.model.indicator = .warning
            default: hud.model.status = "Copied raw — ⌘V"; hud.model.indicator = .clipboard
            }
            hud.announce(hud.model.status)
            hud.hide(after: 1.5)
        }
    }
}

/// Runs on the audio thread: forwards frames to the socket in order and measures levels.
final class CaptureSink: @unchecked Sendable {
    private let session: StreamSession
    private let onLevel: @Sendable (Level) -> Void
    private let onSilence: @Sendable () -> Void
    private let lock = NSLock()
    private var guardState = SilenceGuard()
    private var clock: TimeInterval = 0

    init(session: StreamSession, onLevel: @escaping @Sendable (Level) -> Void, onSilence: @escaping @Sendable () -> Void) {
        self.session = session
        self.onLevel = onLevel
        self.onSilence = onSilence
    }

    func handle(_ frame: Data) {
        session.sendAudio(frame)
        let level = Level(pcm16: frame)
        let silent = lock.withLock { () -> Bool in
            clock += Double(frame.count / 2) / PCMConverter.sampleRate
            return guardState.feed(level, at: clock)
        }
        onLevel(level)
        if silent { onSilence() }
    }
}
