import AppKit
import ChirpCore
import ChirpSpeakers
import ChirpUI

/// Live Notes glue: its own microphone capture, the `NotesRecorder`, the ⌃⌥N hotkey and the window's model. Notes and
/// dictation never run together (the AppDelegate wires the checks both ways). Logs carry state names and counts only.
@MainActor
final class NotesController {
    static let hotkeyID: UInt32 = 4

    let model = NotesModel()
    private(set) lazy var recorder = NotesRecorder(
        makeSession: { StreamSession(config: settings.serverConfig(), options: $0) },
        structure: { request in try await Self.structure(request) },
        reorganize: { request in try await Self.reorganize(request) },
        options: settings.notesStartOptions(health: nil), structuring: settings.notesStructureEnabled(health: nil),
        autoReorganize: settings.notesAutoReorganize)

    /// The server's structure timeout (30 s) plus a margin.
    static let structureTimeout: TimeInterval = 35
    /// A reorganize pass may take longer (up to 3500 chars in and out).
    static let reorganizeTimeout: TimeInterval = 50

    /// One structuring call, logged with counts and the guard name only.
    private nonisolated static func structure(_ request: NotesStructureRequest) async throws -> NotesStructureResponse {
        try await timed({ try await settings.serverConfig().structureNotes(request, timeout: structureTimeout) }) { result, ms in
            chirpLog.info("notes structure chars=\(request.transcript.count, privacy: .public) result=\(result, privacy: .public) ms=\(ms, privacy: .public)")
        } result: { $0.structured ? "ok" : $0.failureLabel }
    }

    /// One reorganize call, logged with counts and the guard name only.
    private nonisolated static func reorganize(_ request: NotesReorganizeRequest) async throws -> NotesReorganizeResponse {
        try await timed({ try await settings.serverConfig().reorganizeNotes(request, timeout: reorganizeTimeout) }) { result, ms in
            chirpLog.info("notes reorganize chars=\(request.notes.count, privacy: .public) scope=\(request.range.length, privacy: .public) result=\(result, privacy: .public) ms=\(ms, privacy: .public)")
        } result: { $0.reorganized ? ($0.changed ? "changed" : "unchanged") : $0.failureLabel }
    }

    /// Runs `call`, then logs its outcome (`result` of the answer, or the error code) and duration.
    private nonisolated static func timed<R: Sendable>(_ call: () async throws -> R, log: (String, Int) -> Void,
                                                      result: (R) -> String) async throws -> R {
        let start = ContinuousClock.now
        func ms() -> Int {
            let e = (ContinuousClock.now - start).components
            return Int(Double(e.seconds) * 1000 + Double(e.attoseconds) / 1e15)
        }
        do {
            let r = try await call()
            log(result(r), ms())
            return r
        } catch let error as NotesStructureError {
            log(error.code, ms())
            throw error
        } catch {
            log((error as? URLError)?.code == .timedOut ? "timeout" : "http", ms())
            throw error
        }
    }

    var health: () -> Health? = { nil }
    var isDictating: () -> Bool = { false }
    var onChange: (() -> Void)?
    /// Show the window; `focus` is false when started from the hotkey (it must not steal focus).
    var onShowWindow: ((_ focus: Bool) -> Void)?
    /// Asks before the one-time speaker model download (the window shows it as a sheet); `done(true)` downloads.
    var confirmSpeakerDownload: ((_ message: String, _ done: @escaping (Bool) -> Void) -> Void)?
    /// The speaker model was downloaded or removed (Settings shows it).
    var onSpeakerModelChange: (() -> Void)?

    /// Speaker labels: the switch, consent, offline loads, Remove and this document's diarizer.
    let speakers = SpeakerLabels(store: SortformerModelStore(), enabled: settings.notesSpeakerLabels,
                                 onPreference: { settings.notesSpeakerLabels = $0 })

    private let capture = AudioCapture(engine: SystemCaptureEngine(pickedDevice: { InputDevice.pickedID(uid: settings.inputDeviceUID) }))
    private var tick: Timer?
    /// A start that failed before the recorder ran (permission, no input device).
    private var startError: String?
    private var lastAnnouncement = ""
    private var lastState: NotesRecorderState = .idle
    private var lastRecorderState: NotesRecorderState = .idle
    private var lastHealth: Health?
    private var lastReorganize: ReorganizeStatus = .idle
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
        recorder.onPassEvent = { event in
            switch event {
            case .split(let chars, let depth, let parts, let fallbacks):
                chirpLog.info("notes split chars=\(chars, privacy: .public) depth=\(depth, privacy: .public) parts=\(parts, privacy: .public) fallbacks=\(fallbacks, privacy: .public)")
            case .organize(let steps, let failed, let conflict):
                chirpLog.info("notes organize steps=\(steps, privacy: .public) failed=\(failed, privacy: .public) conflict=\(conflict, privacy: .public)")
            }
        }
        model.tab = NotesTab(rawValue: settings.notesTab) ?? .notes
        model.structureEnabled = false
        model.onRecordToggle = { [weak self] in self?.toggle(fromHotkey: false) }
        model.onStructureToggle = { [weak self] on in self?.setStructure(on) }
        model.onTabChange = { settings.notesTab = $0.rawValue }
        model.preview = settings.notesPreview
        model.autoReorganize = settings.notesAutoReorganize
        model.onPreviewToggle = { settings.notesPreview = $0 }
        model.onAutoReorganizeToggle = { [weak self] on in
            settings.notesAutoReorganize = on
            self?.recorder.setAutoReorganize(on)
        }
        model.onUserEdit = { [weak self] range, text, kind in self?.recorder.userEdit(range, text, kind: kind) }
        model.onReorganize = { [weak self] in self?.recorder.reorganizeNow() }
        model.onEditorFocus = { [weak self] inTail, composing in self?.recorder.setEditorFocus(inTail: inTail, composing: composing) }
        model.onSpeakerLabelsToggle = { [weak self] on in self?.setSpeakerLabels(on) }
        recorder.onLabels = { [weak self] lag, tentative in
            guard let self else { return }
            chirpLog.info("\(SpeakerLog.labels(speakers: self.recorder.document.speakerCount, lag: lag, tentative: tentative), privacy: .public)")
        }
        speakers.onChange = { [weak self] in
            self?.sync()
            self?.onSpeakerModelChange?()
        }
        speakers.confirm = { [weak self] prompt, done in
            let message = switch prompt {
            case .download(let size): NotesStatus.speakerDownloadPrompt(size: size)
            case .redownload(let size): NotesStatus.speakerRedownloadPrompt(size: size)
            }
            (self?.confirmSpeakerDownload ?? { _, done in done(false) })(message, done)
        }
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
        if speakers.needsLoad {
            // The model loads offline (~0.1 s warm); recording starts as soon as it is ready, or without labels if
            // it is gone (labels turn off: nothing downloads without the user's Download).
            guard !speakers.isLoading else { return }
            Task {
                _ = await speakers.prepare()
                self.start(focus: focus)
            }
            return
        }
        let health = resolvedHealth()
        startError = nil
        let diarizer = speakers.readyDiarizer()
        let labels = diarizer != nil
        recorder.speakers = diarizer
        recorder.options = settings.notesStartOptions(health: health, speakerLabels: labels)
        recorder.serverHost = settings.serverConfig().host
        applyAvailability(health)
        if model.structuring == .off(.correctionOff) || model.structuring == .off(.unsupported), model.tab == .notes, recorder.document.isEmpty {
            model.tab = .transcript   // structuring unavailable: the transcript is the useful view
        }
        chirpLog.info("notes start microphone=\(Permissions.microphone.rawValue, privacy: .public) correction=\(self.recorder.options.correction, privacy: .public) structuring=\(String(describing: self.recorder.structuring), privacy: .public) speakers=\(labels, privacy: .public)")
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
        speakers.reset()
        recorder.speakers = nil
    }

    // MARK: speaker labels

    /// The footer's "Label speakers" switch (applies from the next Record).
    private func setSpeakerLabels(_ on: Bool) {
        guard !isActive else { return }
        speakers.setEnabled(on, documentHasLabels: recorder.document.speakerCount > 0)
        if !speakers.enabled, speakers.diarizer == nil { recorder.speakers = nil }
    }

    /// Settings › Remove: deletes the model, partial downloads too; refused while recording or loading.
    func removeSpeakerModel() {
        guard !isActive, speakers.remove() else { NSSound.beep(); return }
        recorder.speakers = nil
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
        model.speakerLabels = speakers.enabled
        model.speakerModel = speakers.model
        let reorganize = recorder.reorganizeStatus
        model.reorganizeStatus = reorganize
        // The editor replays the AI changes right away, onto text that matches `model.document` before them.
        model.enqueue(recorder.takePendingChanges())
        model.debugRetention = recorder.debugRetention || (resolvedHealth()?.debugRetention ?? false)
        model.elapsed = recorder.elapsed
        model.finishingElapsed = recorder.stoppingElapsed
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setTicking(recorder.state.isActive)
        let announcement = model.announcement
        if announcement != lastAnnouncement {
            lastAnnouncement = announcement
            if !announcement.isEmpty { announce(announcement) }
        }
        if reorganize != lastReorganize {
            if case .applied = reorganize { announce(NotesStatus.reorganized) }
            lastReorganize = reorganize
        }
        onChange?()
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
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
                self.model.finishingElapsed = self.recorder.stoppingElapsed
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
