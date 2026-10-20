import AppKit
import ChirpCore
import ChirpUI

/// Live Notes glue: its own microphone capture, the `NotesRecorder`, the ⌃⌥N hotkey and the window's model. Notes and
/// dictation never run together (the AppDelegate wires the checks both ways). Logs carry state names and counts only.
@MainActor
final class NotesController {
    static let hotkeyID: UInt32 = 4

    let model = NotesModel()
    private(set) lazy var recorder = NotesRecorder(
        makeSession: { StreamSession(config: settings.serverConfig(), options: $0) },
        structure: { request in try await settings.serverConfig().structureNotes(request, timeout: Self.structureTimeout) },
        options: settings.notesStartOptions(health: nil), structuring: settings.notesStructureEnabled(health: nil))

    /// The server's structure timeout (30 s) plus a margin.
    static let structureTimeout: TimeInterval = 35

    var health: () -> Health? = { nil }
    var isDictating: () -> Bool = { false }
    var onChange: (() -> Void)?
    /// Show the window; `focus` is false when started from the hotkey (it must not steal focus).
    var onShowWindow: ((_ focus: Bool) -> Void)?

    private let capture = AudioCapture(engine: SystemCaptureEngine(pickedDevice: { InputDevice.pickedID(uid: settings.inputDeviceUID) }))
    private var tick: Timer?
    /// A start that failed before the recorder ran (permission, no input device).
    private var startError: String?
    private var lastAnnouncement = ""
    private var lastState: NotesRecorderState = .idle
    private var lastRecorderState: NotesRecorderState = .idle
    private var lastHealth: Health?
    /// The last health this server answered with, kept across a failed poll so one blip never changes what
    /// structuring may do (dropped when the server URL changes).
    private var knownHealth: (url: String, health: Health)?

    private(set) lazy var gate = PauseGate(
        register: { [weak self] in
            HotKeyCenter.shared.register(id: Self.hotkeyID, combo: .controlOptionN, onDown: { [weak self] in self?.toggle(fromHotkey: true) })
        },
        unregister: { HotKeyCenter.shared.unregister(id: Self.hotkeyID) },
        onChange: { [weak self] in self?.onChange?() })

    init() {
        recorder.onChange = { [weak self] in self?.sync() }
        model.tab = NotesTab(rawValue: settings.notesTab) ?? .notes
        model.structureEnabled = false
        model.onRecordToggle = { [weak self] in self?.toggle(fromHotkey: false) }
        model.onStructureToggle = { [weak self] on in self?.setStructure(on) }
        model.onTabChange = { settings.notesTab = $0.rawValue }
        sync()
    }

    var isRecording: Bool { recorder.state.isCapturing }
    var isActive: Bool { recorder.state.isActive }
    var hasDocument: Bool { !recorder.document.segments.isEmpty }

    @discardableResult
    func registerHotkey() -> Bool { gate.registerHotkey() }

    /// The menu's switch: pausing Chirp stops Notes gracefully (the notes stay) and releases ⌃⌥N.
    func setRunning(_ running: Bool) {
        if !running, isRecording { Task { await stop() } }
        gate.setRunning(running)
    }

    // MARK: recording

    func toggle(fromHotkey: Bool) {
        if isRecording { Task { await stop() }; return }
        guard recorder.state != .stopping else { return }
        start(focus: !fromHotkey)
    }

    func start(focus: Bool) {
        guard !gate.isPaused, !isActive else { return }
        guard !isDictating() else { NSSound.beep(); return }
        onShowWindow?(focus)
        let health = resolvedHealth()
        startError = nil
        recorder.options = settings.notesStartOptions(health: health)
        recorder.serverHost = settings.serverConfig().host
        applyAvailability(health)
        if model.structuring == .off(.correctionOff) || model.structuring == .off(.unsupported), model.tab == .notes, recorder.document.isEmpty {
            model.tab = .transcript   // structuring unavailable: the transcript is the useful view
        }
        chirpLog.info("notes start microphone=\(Permissions.microphone.rawValue, privacy: .public) correction=\(self.recorder.options.correction, privacy: .public) structuring=\(String(describing: self.recorder.structuring), privacy: .public)")
        if settings.soundsEnabled { Sounds.play(.start) }
        let micMayOpen = ContinuousClock.now + .seconds(Sounds.startDelay())
        recorder.start()
        Task {
            guard await Permissions.requestMicrophone() else {
                Permissions.openSettings(.microphone)
                await fail("Microphone access denied — enable it in System Settings")
                return
            }
            try? await Task.sleep(until: micMayOpen, clock: .continuous)
            guard isRecording else { return }
            openMicrophone()
        }
    }

    private func openMicrophone() {
        let sink = NotesCaptureSink(recorder: recorder) { [weak self] in
            Task { @MainActor in await self?.fail("No microphone signal") }
        }
        do {
            try capture.start(onFailure: { [weak self] in
                Task { @MainActor in await self?.fail("The microphone stopped — check the input device") }
            }) { sink.handle($0) }
        } catch {
            Task { await fail(error is CaptureError ? "No microphone input device" : "Could not start the microphone") }
        }
    }

    /// Stop: the microphone closes at once, then the last segment finalizes and the final pass runs.
    func stop() async {
        guard isRecording else { return }
        capture.stop()
        if settings.soundsEnabled { Sounds.play(.stop) }
        await recorder.stop()
    }

    private func fail(_ message: String) async {
        capture.stop()
        if isRecording {
            await recorder.fail(message)
        } else if NotesModel.acceptsStartError(recorder.state) {
            // Only a start that never got going; a race with Stop (the recorder is finishing) is not an error.
            startError = message
            sync()
        }
    }

    /// Quit: finish gracefully for at most `limit`, then drop what is still in flight.
    func stopForQuit(limit: Duration = .seconds(5)) async {
        guard isActive else { return }
        capture.stop()
        let finished = AsyncStream<Void>.makeStream()
        Task { if self.isRecording { await self.recorder.stop() } else { await self.waitWhileStopping() }; finished.continuation.yield() }
        Task { try? await Task.sleep(for: limit); finished.continuation.yield() }
        for await _ in finished.stream { break }
        if isActive { recorder.cancel() }
    }

    private func waitWhileStopping() async {
        while recorder.state == .stopping { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// New (after the dirty guard): an empty document.
    func reset() {
        guard !isActive else { return }
        startError = nil
        recorder.reset()
    }

    func markSaved() { recorder.markSaved() }

    // MARK: structuring

    private func setStructure(_ on: Bool) {
        settings.setNotesStructure(on, health: resolvedHealth())
        applyAvailability(resolvedHealth())
    }

    /// The server's health, or the last answer from the same server when a poll just failed.
    private func resolvedHealth() -> Health? {
        let url = settings.serverURL
        if let h = health() {
            knownHealth = (url, h)
            return h
        }
        guard let known = knownHealth, known.url == url else { return nil }
        return known.health
    }

    /// New server health (or the toggle): what structuring may do, and the privacy line.
    func healthChanged() {
        let h = resolvedHealth()
        guard h != lastHealth else { return }
        lastHealth = h
        if !isActive { recorder.options = settings.notesStartOptions(health: h) }
        applyAvailability(h)
    }

    private func applyAvailability(_ health: Health?) {
        let enabled = settings.notesStructureEnabled(health: health)
        model.structureEnabled = enabled
        recorder.configureStructuring(enabled: enabled, health: health)
        var line = NotesStatus.privacy
        if enabled, health?.correctionLeavesMachine == true {
            line += " · Structuring sends text to \(health?.correctionHost ?? settings.serverConfig().host)"
        }
        model.privacyLine = line
        model.canManageModels = settings.serverConfig().isLoopback
        sync()
    }

    // MARK: model

    private func sync() {
        if recorder.state != lastRecorderState {
            // The recorder moved on: an earlier start error no longer describes it.
            lastRecorderState = recorder.state
            startError = nil
        }
        let state = NotesModel.displayState(recorder: recorder.state, startError: startError)
        if state != lastState {
            chirpLog.info("notes \(String(describing: self.lastState.logName), privacy: .public) -> \(state.logName, privacy: .public) segments=\(self.recorder.document.segments.count, privacy: .public) chars=\(self.recorder.document.text.utf16.count, privacy: .public) tail=\(self.recorder.document.tail.utf16.count, privacy: .public)")
            lastState = state
            if !recorder.state.isCapturing { capture.stop() }
        }
        model.state = state
        model.document = recorder.document
        model.structuring = recorder.structuring
        model.debugRetention = recorder.debugRetention || (resolvedHealth()?.debugRetention ?? false)
        model.elapsed = recorder.elapsed
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setTicking(recorder.state.isCapturing)
        let announcement = model.announcement
        if announcement != lastAnnouncement {
            lastAnnouncement = announcement
            if !announcement.isEmpty {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
        onChange?()
    }

    /// The elapsed time in the window and the menu header, once a second while recording.
    private func setTicking(_ on: Bool) {
        guard on != (tick != nil) else { return }
        tick?.invalidate()
        tick = nil
        guard on else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.elapsed = self.recorder.elapsed
                self.onChange?()
            }
        }
    }

    /// The menu's view of Notes.
    var menuState: MenuBarController.NotesMenuState {
        MenuBarController.NotesMenuState(
            recording: isRecording, finishing: recorder.state == .stopping,
            elapsed: model.elapsedText, hasDocument: hasDocument,
            hotkeyRegistered: gate.hotkeyRegistered, debugRetention: isRecording && recorder.debugRetention)
    }
}

private extension NotesRecorderState {
    /// The state's name for the log, never an error message (which could quote the server).
    var logName: String {
        switch self {
        case .idle: "idle"
        case .starting: "starting"
        case .recording: "recording"
        case .stopping: "stopping"
        case .stopped: "stopped"
        case .error: "error"
        }
    }
}

/// Runs on the audio thread: the silence guard, then the frame to the recorder (which routes it and runs the segmenter).
final class NotesCaptureSink: @unchecked Sendable {
    private let recorder: NotesRecorder
    private let onSilence: @Sendable () -> Void
    private let lock = NSLock()
    private var guardState = SilenceGuard()
    private var clock: TimeInterval = 0

    init(recorder: NotesRecorder, onSilence: @escaping @Sendable () -> Void) {
        self.recorder = recorder
        self.onSilence = onSilence
    }

    func handle(_ frame: Data) {
        let level = Level(pcm16: frame)
        let silent = lock.withLock { () -> Bool in
            clock += Double(frame.count / 2) / PCMConverter.sampleRate
            return guardState.feed(level, at: clock)
        }
        recorder.handleFrame(frame, level: level)
        if silent { onSilence() }
    }
}
