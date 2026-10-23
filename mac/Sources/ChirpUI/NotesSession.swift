import ChirpCore
import Foundation

/// Everything `NotesSession` reaches outside itself: the microphone engine, the sockets, the structuring calls, time,
/// permissions, sounds, the hotkey and accessibility. The app passes the system ones (`NotesController.swift`);
/// tests pass fakes, so a whole session runs without a microphone, TCC, a window or the user's server.
public struct NotesSessionDependencies {
    public var settings: Preferences
    public var engine: CaptureEngine
    public var makeSession: (StartOptions) -> StreamSession
    public var structure: NotesRecorder.Structure
    public var reorganize: NotesRecorder.Reorganize
    public var speakerStore: SpeakerModelStore
    /// Where the crash-recovery journal lives (tests pass a temporary directory).
    public var journalStore: NotesJournalStore
    /// The guard that stops Notes on digital silence (one per microphone start).
    public var silenceGuard: () -> SilenceGuard = { SilenceGuard() }
    public var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    public var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// Starts the once-a-second elapsed tick; the returned closure stops it.
    public var startTicker: (_ tick: @escaping @MainActor () -> Void) -> () -> Void = NotesSessionDependencies.timerTicker
    public var requestMicrophone: () async -> Bool = { true }
    /// The microphone was denied: open its Settings pane.
    public var openMicrophoneSettings: () -> Void = {}
    /// The microphone authorization status, for the log.
    public var microphoneStatus: () -> Int = { 3 }
    /// Plays a cue; the session checks the sounds switch first.
    public var play: (SoundCue) -> Void = { _ in }
    /// How long the microphone waits after the start cue begins.
    public var soundStartDelay: () -> TimeInterval = { 0 }
    public var beep: () -> Void = {}
    /// A VoiceOver announcement.
    public var announce: (String) -> Void = { _ in }
    public var reduceMotion: () -> Bool = { false }
    /// Registers ⌃⌥N; false when another app owns it.
    public var registerHotkey: (_ onDown: @escaping () -> Void) -> Bool = { _ in false }
    public var unregisterHotkey: () -> Void = {}

    public init(settings: Preferences, engine: CaptureEngine, makeSession: @escaping (StartOptions) -> StreamSession,
                structure: @escaping NotesRecorder.Structure, reorganize: @escaping NotesRecorder.Reorganize,
                speakerStore: SpeakerModelStore, journalStore: NotesJournalStore) {
        self.settings = settings
        self.engine = engine
        self.makeSession = makeSession
        self.structure = structure
        self.reorganize = reorganize
        self.speakerStore = speakerStore
        self.journalStore = journalStore
    }

    public static func timerTicker(_ tick: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        return { timer.invalidate() }
    }
}

/// Live Notes glue: its own microphone capture, the `NotesRecorder`, the ⌃⌥N hotkey and the window's model. Notes and
/// dictation never run together (the AppDelegate wires the checks both ways). Logs carry state names and counts only.
@MainActor
public final class NotesSession {
    public let model = NotesModel()
    public let recorder: NotesRecorder
    private let deps: NotesSessionDependencies
    private var settings: Preferences { deps.settings }

    public var health: () -> Health? = { nil }
    public var isDictating: () -> Bool = { false }
    public var onChange: (() -> Void)?
    /// Show the window; `focus` is false when started from the hotkey (it must not steal focus).
    public var onShowWindow: ((_ focus: Bool) -> Void)?
    /// Asks before the one-time speaker model download (the window shows it as a sheet); `done(true)` downloads.
    public var confirmSpeakerDownload: ((_ message: String, _ done: @escaping (Bool) -> Void) -> Void)?
    /// The speaker model was downloaded or removed (Settings shows it).
    public var onSpeakerModelChange: (() -> Void)?

    /// Speaker labels: the switch, consent, offline loads, Remove and this document's diarizer.
    public let speakers: SpeakerLabels
    /// The crash-recovery journal and the opt-in "keep this file up to date" writes.
    public let journal: NotesJournal
    /// Sessions the journal found at launch, newest first; the first is on offer in the window.
    private var recoverable: [NotesJournalRecord] = []

    private let capture: AudioCapture
    private var stopTick: (() -> Void)?
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

    public private(set) lazy var gate = PauseGate(
        register: { [weak self] in
            self?.deps.registerHotkey({ [weak self] in self?.toggle(fromHotkey: true) }) ?? false
        },
        unregister: { [weak self] in self?.deps.unregisterHotkey() },
        onChange: { [weak self] in self?.onChange?() })

    public init(_ deps: NotesSessionDependencies) {
        self.deps = deps
        let settings = deps.settings
        capture = AudioCapture(engine: deps.engine)
        recorder = NotesRecorder(
            makeSession: deps.makeSession, structure: deps.structure, reorganize: deps.reorganize,
            now: deps.now, sleep: deps.sleep,
            options: settings.notesStartOptions(health: nil), structuring: settings.notesStructureEnabled(health: nil),
            autoReorganize: settings.notesAutoReorganize)
        speakers = SpeakerLabels(store: deps.speakerStore, enabled: settings.notesSpeakerLabels,
                                 onPreference: { settings.notesSpeakerLabels = $0 })
        journal = NotesJournal(store: deps.journalStore, enabled: settings.notesRecoveryCopy, sleep: deps.sleep)
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
        journal.onWrite = { bytes, ms in
            chirpLog.info("notes journal bytes=\(bytes ?? -1, privacy: .public) ms=\(ms, privacy: .public)")
        }
        journal.onKeepSaved = { [weak self] in self?.markSaved() }
        journal.onKeepChange = { [weak self] in self?.sync() }
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

    public var isRecording: Bool { recorder.state.isCapturing }
    public var isActive: Bool { recorder.state.isActive }
    public var hasDocument: Bool { !recorder.document.segments.isEmpty }
    /// The microphone is open.
    public var isCapturing: Bool { capture.isRunning }

    @discardableResult
    public func registerHotkey() -> Bool { gate.registerHotkey() }

    /// The menu's switch: pausing Chirp stops Notes gracefully (the notes stay) and releases ⌃⌥N.
    public func setRunning(_ running: Bool) {
        if !running, isRecording { Task { await stop() } }
        gate.setRunning(running)
    }

    // MARK: recording

    public func toggle(fromHotkey: Bool) {
        if isRecording { Task { await stop() }; return }
        guard recorder.state != .stopping else { return }
        start(focus: !fromHotkey)
    }

    public func start(focus: Bool) {
        guard !gate.isPaused, !isActive else { return }
        guard !isDictating() else { deps.beep(); return }
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
        chirpLog.info("notes start microphone=\(self.deps.microphoneStatus(), privacy: .public) correction=\(self.recorder.options.correction, privacy: .public) structuring=\(String(describing: self.recorder.structuring), privacy: .public) speakers=\(labels, privacy: .public)")
        if settings.soundsEnabled { deps.play(.start) }
        let micMayOpen = deps.now() + deps.soundStartDelay()
        recorder.start()
        Task {
            guard await deps.requestMicrophone() else {
                deps.openMicrophoneSettings()
                await fail("Microphone access denied — enable it in System Settings")
                return
            }
            let wait = micMayOpen - deps.now()
            if wait > 0 { await deps.sleep(.seconds(wait)) }
            guard isRecording else { return }
            openMicrophone()
        }
    }

    private func openMicrophone() {
        let sink = NotesCaptureSink(recorder: recorder, silenceGuard: deps.silenceGuard()) { [weak self] in
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
    public func stop() async {
        guard isRecording else { return }
        capture.stop()
        if settings.soundsEnabled { deps.play(.stop) }
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
    public func stopForQuit(limit: Duration = .seconds(5)) async {
        guard isActive else { return }
        capture.stop()
        let finished = AsyncStream<Void>.makeStream()
        let sleep = deps.sleep
        Task { if self.isRecording { await self.recorder.stop() } else { await self.waitWhileStopping() }; finished.continuation.yield() }
        Task { await sleep(limit); finished.continuation.yield() }
        for await _ in finished.stream { break }
        if isActive { recorder.cancel() }
    }

    private func waitWhileStopping() async {
        while recorder.state == .stopping { await deps.sleep(.milliseconds(100)) }
    }

    /// New (after the dirty guard): an empty document.
    public func reset() {
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
    public func removeSpeakerModel() {
        guard !isActive, speakers.remove() else { deps.beep(); return }
        recorder.speakers = nil
    }

    public func markSaved() { recorder.markSaved() }

    /// Save… wrote `url`: the document is saved, and with `keep` the file follows later changes.
    public func didSave(to url: URL, keep: Bool) {
        recorder.markSaved()
        journal.didSave(to: url, keep: keep)
        chirpLog.info("notes saved keep=\(keep, privacy: .public)")
        sync()
    }

    /// Discard (the quit alert, where no New follows): the recovery copy goes with the notes.
    public func discardJournal() { journal.discard() }

    // MARK: recovery

    /// At launch: a journal left by a session that did not end with Save or Discard is offered in the window.
    /// Returns whether there is one.
    @discardableResult
    public func checkRecovery() -> Bool {
        recoverable = journal.store.recoverable()
        offerRecovery()
        return model.recovery != nil
    }

    private func offerRecovery() {
        model.recovery = recoverable.first.map { RecoveryOffer(startedAt: $0.document.startedAt, elapsed: $0.elapsed) }
        if let first = recoverable.first {
            chirpLog.info("notes recovery offered segments=\(first.document.segments.count, privacy: .public) chars=\(first.document.text.utf16.count, privacy: .public)")
        }
    }

    /// The offered session, for Save… (it is written without being loaded).
    public var offeredDocument: NotesDocument? { recoverable.first?.document }

    /// Keep: the offered session becomes the stopped, still unsaved document (the caller asked about the current one).
    public func keepRecovered() {
        guard !isActive, !recoverable.isEmpty else { return }
        let record = recoverable.removeFirst()
        journal.discard()
        journal.adopt(record)
        recorder.restore(record.document, elapsed: record.elapsed)
        model.recovery = nil
        chirpLog.info("notes recovery kept segments=\(record.document.segments.count, privacy: .public)")
        sync()
    }

    /// Discard or Save…: the offered journal is deleted and the next one (if any) is offered.
    public func dropRecovered() {
        guard !recoverable.isEmpty else { return }
        journal.discard(recoverable.removeFirst().document.id)
        offerRecovery()
    }

    /// The Settings switch changed: the footer line follows, and turning it off deletes the copy.
    public func recoveryCopyChanged() {
        journal.setEnabled(settings.notesRecoveryCopy)
        applyAvailability(resolvedHealth())
    }

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
    public func healthChanged() {
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
        var line = settings.notesRecoveryCopy ? NotesStatus.privacyRecovery : NotesStatus.privacy
        model.privacyHelp = settings.notesRecoveryCopy ? NotesStatus.privacyRecoveryHelp : ""
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
        let leftCapture = state != lastState && !state.isCapturing
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
        let changes = recorder.takePendingChanges()
        model.enqueue(changes)
        journal.update(recorder.document, elapsed: recorder.elapsed, urgent: !changes.isEmpty || leftCapture)
        model.keepSaving = journal.keepStatus
        model.debugRetention = recorder.debugRetention || (resolvedHealth()?.debugRetention ?? false)
        model.elapsed = recorder.elapsed
        model.finishingElapsed = recorder.stoppingElapsed
        model.reduceMotion = deps.reduceMotion()
        setTicking(recorder.state.isActive)
        let announcement = model.announcement
        if announcement != lastAnnouncement {
            lastAnnouncement = announcement
            if !announcement.isEmpty { deps.announce(announcement) }
        }
        if reorganize != lastReorganize {
            if case .applied = reorganize { deps.announce(NotesStatus.reorganized) }
            lastReorganize = reorganize
        }
        onChange?()
    }

    /// The elapsed time in the window and the menu header, once a second while recording.
    private func setTicking(_ on: Bool) {
        guard on != (stopTick != nil) else { return }
        stopTick?()
        stopTick = nil
        guard on else { return }
        stopTick = deps.startTicker { [weak self] in
            guard let self else { return }
            self.model.elapsed = self.recorder.elapsed
            self.model.finishingElapsed = self.recorder.stoppingElapsed
            self.onChange?()
        }
    }
}

extension NotesRecorderState {
    /// The state's name for the log, never an error message (which could quote the server).
    public var logName: String {
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
public final class NotesCaptureSink: @unchecked Sendable {
    private let recorder: NotesRecorder
    private let onSilence: @Sendable () -> Void
    private let lock = NSLock()
    private var guardState: SilenceGuard
    private var clock: TimeInterval = 0

    public init(recorder: NotesRecorder, silenceGuard: SilenceGuard = SilenceGuard(), onSilence: @escaping @Sendable () -> Void) {
        self.recorder = recorder
        self.onSilence = onSilence
        guardState = silenceGuard
    }

    public func handle(_ frame: Data) {
        let level = Level(pcm16: frame)
        let silent = lock.withLock { () -> Bool in
            clock += Double(frame.count / 2) / PCMConverter.sampleRate
            return guardState.feed(level, at: clock)
        }
        recorder.handleFrame(frame, level: level)
        if silent { onSilence() }
    }
}
