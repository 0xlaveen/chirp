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

    let hud = HUDController()
    private let capture = AudioCapture()
    private let inserter = TextInserter(env: SystemInsertion.environment(), pasteboard: SystemPasteboard())

    private var session: StreamSession?
    private var eventTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var epoch = 0
    private var pendingFinal: FinalResult?
    private var lastInsertion: (final: FinalResult, outcome: InsertionOutcome)?

    static let dictateID: UInt32 = 1
    private static let escapeID: UInt32 = 2

    /// (Re)registers the dictation hotkey from settings.
    @discardableResult
    func registerHotkey() -> Bool {
        HotKeyCenter.shared.register(id: Self.dictateID, combo: Settings.hotkey,
                                     onDown: { [weak self] in self?.hotkeyDown() },
                                     onUp: { [weak self] in self?.hotkeyUp() })
    }

    var state: DictationState { machine.state }
    var debugRetention: Bool { hud.model.debugRetention || (health?.debugRetention ?? false) }

    // MARK: input from the hotkeys

    func hotkeyDown() { send(.hotkeyDown(at: ProcessInfo.processInfo.systemUptime)) }
    func hotkeyUp() { send(.hotkeyUp(at: ProcessInfo.processInfo.systemUptime)) }
    func escape() { send(.escape) }

    // MARK: health

    func refreshHealth() async {
        let config = Settings.serverConfig()
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
            // Esc is only claimed while a dictation is active, so it is untouched the rest of the time.
            if [.connecting, .listening, .finalizing].contains(machine.state) {
                HotKeyCenter.shared.register(id: Self.escapeID, combo: .escape) { [weak self] in self?.escape() }
            } else {
                HotKeyCenter.shared.unregister(id: Self.escapeID)
            }
            renderStatus()
            onChange?()
        }
        for effect in effects { run(effect) }
    }

    private func renderStatus() {
        switch machine.state {
        case .idle, .inserting: break
        case .connecting: hud.model.status = "Connecting…"
        case .listening: hud.model.status = "Listening"; hud.announce("Listening")
        case .finalizing: hud.model.status = "Finalizing"
        case .error(let m): hud.model.status = m; hud.model.isError = true
        }
    }

    private func run(_ effect: DictationEffect) {
        switch effect {
        case .start: begin()
        case .finalize: finalize()
        case .cancel: teardown(cancelServer: true); hud.hide()
        case .abort(let message):
            teardown(cancelServer: true)
            hud.model.status = message
            hud.model.isError = true
            hud.model.level = 0
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
        hud.hide()
        hud.model.reset()
        hud.model.status = "Connecting…"
        hud.model.debugRetention = health?.debugRetention ?? false
        hud.show()

        Task {
            guard await Permissions.requestMicrophone() else {
                if epoch == myEpoch, machine.state.isActive {
                    Permissions.openSettings(.microphone)
                    send(.failed("Microphone access denied — enable it in System Settings"))
                }
                return
            }
            guard epoch == myEpoch, machine.state == .connecting || machine.state == .listening else { return }
            startStreaming(epoch: myEpoch)
        }
    }

    private func startStreaming(epoch myEpoch: Int) {
        let session = StreamSession(config: Settings.serverConfig(),
                                    options: StartOptions(client: "mac", correction: Settings.correction))
        self.session = session
        let sink = CaptureSink(session: session) { [weak self] level in
            Task { @MainActor in
                guard let self, self.epoch == myEpoch else { return }
                self.hud.model.level = level.rms
            }
        } onSilence: { [weak self] in
            Task { @MainActor in
                guard let self, self.epoch == myEpoch, self.machine.state.isActive else { return }
                self.send(.failed("No microphone signal"))
            }
        }
        do {
            try capture.start { sink.handle($0) }
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
        case .message(.final(let f)):
            pendingFinal = f
            send(.finalReceived)
        case .message(.error(let code, let message)):
            send(.failed(Self.friendly(code: code, message: message)))
        case .message(.unknown): break
        case .closed(let reason):
            if [.connecting, .listening, .finalizing].contains(machine.state) {
                send(.failed(reason ?? "Connection closed"))
            }
        }
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
        hud.model.level = 0
        let session = self.session, myEpoch = epoch
        Task { await session?.stop() }
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let self, self.epoch == myEpoch, self.machine.state == .finalizing else { return }
            self.send(.failed("Timed out waiting for the transcript"))
        }
    }

    private func stopCapture() { if capture.isRunning { capture.stop() } }

    private func teardown(cancelServer: Bool) {
        epoch += 1   // invalidates every in-flight callback of the old session
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
        guard let final = pendingFinal else { send(.insertionFinished); return }
        let text = final.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = session
        session = nil
        eventTask?.cancel(); eventTask = nil
        Task { await s?.close() }
        guard !text.isEmpty else {
            hud.model.status = "No speech detected"
            hud.announce("No speech detected")
            hud.model.level = 0
            hud.hide(after: 1.5)
            send(.insertionFinished)
            return
        }
        hud.model.status = "Inserting"
        Task {
            let outcome = await inserter.insert(text)
            lastInsertion = (final, outcome)
            show(outcome, final: final)
            send(.insertionFinished)
        }
    }

    private func show(_ outcome: InsertionOutcome, final: FinalResult) {
        let p = OutcomePresentation.of(outcome, final: final)
        hud.model.status = p.status
        hud.model.isError = p.isError
        hud.model.showUseRaw = p.showUseRaw
        hud.model.onUseRaw = p.showUseRaw ? { [weak self] in self?.useRaw() } : nil
        hud.show()
        hud.hide(after: p.linger)
        hud.announce(p.status)
    }

    /// Replace the inserted correction with the raw transcript: in place for AX insertions, via ⌘Z for pasted ones.
    private func useRaw() {
        guard let last = lastInsertion, last.final.canUseRaw, !machine.state.isActive else { return }
        lastInsertion = nil
        hud.model.showUseRaw = false
        Task {
            let outcome = await inserter.replaceLast(with: last.final.raw)
            hud.model.status = outcome == .copied ? "Copied raw — press ⌘V" : "Inserted raw"
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
