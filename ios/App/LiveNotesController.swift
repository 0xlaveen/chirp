import AVFoundation
import ChirpCore
import ChirpIOSCore
import Foundation
import UIKit

enum NotesAction { case start, togglePause, stop }

/// The paired server for the structuring calls, readable off the main actor.
final class NotesServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ServerConfig?
    var config: ServerConfig? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Live Notes on iPhone and iPad: ChirpCore's `NotesRecorder` (rolling ≤45 s segments over `/v1/stream`, structuring
/// via `/v1/notes/structure` and `/v1/notes/reorganize` on the Mac) wired to its own microphone capture, the encrypted
/// recovery journal, the Live Activity and the app's lifecycle. Notes and a keyboard session never hold the microphone
/// together. Nothing here logs or exports text.
@MainActor
final class LiveNotesController: ObservableObject {
    @MainActor struct Dependencies {
        var server: () -> ServerConfig?
        var correctionAllowed: (Health) -> Bool
        var otherCaptureActive: () -> Bool
        var http: URLSession
        var fetchHealth: (ServerConfig, URLSession) async throws -> Health = { try await $0.fetchHealth(session: $1) }
        var makeStream: (ServerConfig, StartOptions, URLSession) -> StreamSession = { StreamSession(config: $0, options: $1, urlSession: $2) }
        var structure: @Sendable (ServerConfig, URLSession, NotesStructureRequest) async throws -> NotesStructureResponse = {
            try await $0.structureNotes($2, session: $1, timeout: 35)
        }
        var reorganize: @Sendable (ServerConfig, URLSession, NotesReorganizeRequest) async throws -> NotesReorganizeResponse = {
            try await $0.reorganizeNotes($2, session: $1, timeout: 50)
        }
        var audio: any NotesAudio
        var requestPermission: () async -> Bool
        var activity: NotesActivityControl
        var store: NotesStore?
        var copyText: (String) -> Void = { UIPasteboard.general.string = $0 }
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        /// Starts the once-a-second elapsed tick; the returned closure stops it.
        var startTicker: (@escaping @MainActor () -> Void) -> () -> Void = { tick in
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
            return { timer.invalidate() }
        }
        /// Keeps the app running briefly while Stop finishes in the background.
        var backgroundTask: @MainActor (_ expired: @escaping @MainActor () -> Void) -> () -> Void = { expired in
            var id = UIBackgroundTaskIdentifier.invalid
            id = UIApplication.shared.beginBackgroundTask(withName: "Live Notes finishing") { MainActor.assumeIsolated { expired() } }
            return { if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid } }
        }
        /// Audio kept in memory for an offline Mac (less than the Mac's 30 minutes: iOS limits a background app's memory).
        var keptAudio: TimeInterval = 10 * 60
        var observeLifecycle = true
    }

    /// The app's controller, for the Live Activity buttons and Shortcuts (nil until the Notes tab first appears).
    static private(set) var instance: LiveNotesController?

    static let interruptedReason = "Paused · another app or a call took the microphone"
    static let lostReason = "Paused · microphone unavailable"

    @Published private(set) var state: NotesRecorderState = .idle
    @Published private(set) var document = NotesDocument()
    @Published private(set) var structuring: StructuringStatus = .off(.waiting)
    @Published private(set) var reorganize: ReorganizeStatus = .idle
    @Published private(set) var connection: NotesConnection = .online
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var pauseReason: String?
    @Published private(set) var debugRetention = false
    @Published private(set) var snapshots = NotesSnapshots()
    @Published private(set) var recovery: NotesJournalRecord?
    @Published private(set) var health: Health?
    @Published private(set) var notice = ""
    @Published private(set) var preferences = NotesPreferences()
    @Published private(set) var starting = false
    /// Screen updates skipped while locked in battery saver (for the tests and the status line).
    private(set) var skippedUpdates = 0

    let recorder: NotesRecorder
    private var deps: Dependencies
    private let serverBox: NotesServerBox
    private let journal: NotesJournal?
    private var recoverable: [NotesJournalRecord] = []
    private var snaps = NotesSnapshots()
    private var textBefore = ""
    private var lastState: NotesRecorderState = .idle
    private var lastActivity: ChirpNotesActivityAttributes.ContentState?
    private var activityLive = false
    private var stopTick: (() -> Void)?
    private var endBackgroundTask: (() -> Void)?
    private var pausedForInterruption = false
    private var observers: [NSObjectProtocol] = []
    /// The app is in the background (the screen locked or another app in front).
    private(set) var background = false

    init(_ deps: Dependencies) {
        self.deps = deps
        let box = NotesServerBox()
        serverBox = box
        let http = deps.http, structure = deps.structure, reorganize = deps.reorganize, makeStream = deps.makeStream
        let preferences = (try? deps.store?.loadPreferences()) ?? NotesPreferences()
        self.preferences = preferences
        recorder = NotesRecorder(
            // Never reached unpaired: Record needs a pairing, and the box keeps the last one.
            makeSession: { options in makeStream(box.config ?? ServerConfig(baseURL: URL(string: "https://unpaired.invalid")!), options, http) },
            structure: { request in
                guard let config = box.config else { throw NotesStructureError.unsupported(404) }
                return try await structure(config, http, request)
            },
            reorganize: { request in
                guard let config = box.config else { throw NotesStructureError.unsupported(404) }
                return try await reorganize(config, http, request)
            },
            now: deps.now, sleep: deps.sleep, options: StartOptions(client: "ios", wordTimings: true), structuring: false,
            autoReorganize: preferences.autoReorganize, keptAudio: deps.keptAudio)
        let sleep = deps.sleep
        journal = deps.store.map { NotesJournal(store: $0.journalStore, enabled: preferences.recoveryCopy, sleep: sleep) }
        recorder.onChange = { [weak self] in self?.sync() }
        journal?.onKeepSaved = { [weak self] in self?.recorder.markSaved() }
        if preferences.recoveryCopy, let store = deps.store {
            recoverable = store.journalStore.recoverable()
            recovery = recoverable.first
        }
        if deps.observeLifecycle { observeApp() }
        sync()
    }

    var isActive: Bool { recorder.state.isActive }
    var isPaused: Bool { recorder.state == .paused }
    var paired: Bool { deps.server() != nil }

    // MARK: recording

    func record() async {
        guard !recorder.state.isActive, !starting else { return }
        guard let config = deps.server() else { notice = "Pair your Mac first."; return }
        guard !deps.otherCaptureActive() else { notice = "End the keyboard session to record notes."; return }
        starting = true
        defer { starting = false }
        guard await deps.requestPermission() else { notice = SessionFailure.permission.localizedDescription; return }
        serverBox.config = config
        if let fresh = try? await deps.fetchHealth(config, deps.http), fresh.ok { health = fresh; recorder.serverAvailable() }
        guard !recorder.state.isActive, !deps.otherCaptureActive() else { return }
        configure()
        notice = ""
        recorder.start()
        guard openMicrophone() else { await recorder.fail("Microphone unavailable"); return }
        beginActivity()
    }

    func pause(reason: String? = nil) async {
        guard recorder.state == .recording else { return }
        deps.audio.stop()
        await recorder.pause(reason: reason)
    }

    func resume() async {
        guard recorder.state == .paused else { return }
        guard !deps.otherCaptureActive() else { notice = "End the keyboard session to record notes."; return }
        pausedForInterruption = false
        configure()
        await recorder.resume()
        guard recorder.state == .recording else { return }
        if !openMicrophone() { await recorder.pause(reason: Self.lostReason) }
    }

    func togglePause() async { if isPaused { await resume() } else { await pause() } }

    /// Stop: the microphone closes at once, the last segment finalizes and the final pass runs on the Mac. A background
    /// task keeps a locked phone awake for that.
    func stop() async {
        guard recorder.state.isLive else { return }
        deps.audio.stop()
        endBackgroundTask?()
        endBackgroundTask = deps.backgroundTask { [weak self] in self?.recorder.cancel() }
        await recorder.stop()
        endBackgroundTask?(); endBackgroundTask = nil
    }

    func perform(_ action: NotesAction) async -> String {
        switch action {
        case .start:
            await record()
            return recorder.state.isActive ? "Recording notes." : (notice.isEmpty ? "Open Chirp to start Live Notes." : notice)
        case .togglePause:
            guard recorder.state.isLive else { return "Live Notes is not recording." }
            await togglePause()
            return isPaused ? "Live Notes paused. Microphone off." : "Live Notes recording."
        case .stop:
            guard recorder.state.isLive else { return "Live Notes is not recording." }
            await stop()
            return "Live Notes stopped. Your notes are in Chirp."
        }
    }

    @discardableResult
    private func openMicrophone() -> Bool {
        let recorder = self.recorder
        do {
            try deps.audio.start(frame: { data in recorder.handleFrame(data, level: Level(pcm16: data)) },
                                 event: { [weak self] event in Task { @MainActor in await self?.audioEvent(event) } })
            return true
        } catch { return false }
    }

    private func audioEvent(_ event: NotesAudioEvent) async {
        switch event {
        case .interrupted:
            guard recorder.state == .recording else { return }
            pausedForInterruption = true
            await pause(reason: Self.interruptedReason)
        case .resumable:
            guard pausedForInterruption, recorder.state == .paused else { return }
            await resume()
        case .lost:
            guard recorder.state == .recording else { return }
            await pause(reason: Self.lostReason)
        }
    }

    /// New: an empty document (the view asks first when the notes are unsaved).
    func newNotes() {
        guard !recorder.state.isActive else { return }
        recorder.reset()
        snaps.removeAll()
        textBefore = ""
        notice = ""
        sync()
    }

    // MARK: editing and Organize

    /// The editor's text changed. The edit is applied to what the recorder holds now; one that overlaps an AI change
    /// that landed meanwhile is dropped and the editor shows the current text.
    func edit(_ text: String) {
        if let change = NotesEditRebase.change(shown: document.text, edited: text, current: recorder.document.text) {
            recorder.userEdit(change.range, change.replacement)
        }
        publish()
    }

    /// Typing holds structuring appends (up to `NotesRecorder.holdMax` after the last keystroke).
    func setEditing(_ editing: Bool) { recorder.setEditorFocus(inTail: editing, composing: false) }

    func organize() { recorder.reorganizeNow() }

    var canUndoOrganize: Bool { snaps.latest != nil && recorder.state != .stopping }

    /// Undo the last Organize. Returns false when edits since would be lost: the view asks, then calls again confirmed.
    @discardableResult
    func undoOrganize(confirmed: Bool = false) -> Bool {
        guard recorder.state != .stopping, let snapshot = snaps.latest else { return true }
        let current = recorder.document.text
        let target: String
        switch NotesSnapshots.restore(snapshot, now: current) {
        case .text(let text): target = text
        case .replace(let text):
            guard confirmed else { return false }
            target = text
        }
        snaps.remove(snapshot.id)
        if let change = NotesDocument.diff(current, target, kind: .restore) { recorder.restoreText(change.range, change.replacement) }
        sync()
        return true
    }

    // MARK: export

    var markdown: String { recorder.document.exportMarkdown() }

    func copy() { deps.copyText(markdown); notice = "Copied notes and transcript." }

    /// Save to Files wrote the export: the notes are saved, so the recovery copy goes.
    func didExport() { recorder.markSaved(); notice = "Saved to Files." }

    // MARK: recovery

    func keepRecovered() {
        guard !recorder.state.isActive, !recoverable.isEmpty else { return }
        let record = recoverable.removeFirst()
        journal?.discard()
        journal?.adopt(record)
        recorder.restore(record.document, elapsed: record.elapsed)
        snaps.removeAll()
        textBefore = recorder.document.text
        recovery = nil
        sync()
    }

    func discardRecovered() {
        guard !recoverable.isEmpty else { return }
        journal?.discard(recoverable.removeFirst().document.id)
        recovery = recoverable.first
    }

    // MARK: preferences

    func setStructure(_ on: Bool) {
        preferences.structure = on
        preferences.structureConsentHost = on && health?.correctionLeavesMachine == true ? health?.correctionHost : nil
        save()
    }
    func setAutoReorganize(_ on: Bool) { preferences.autoReorganize = on; recorder.setAutoReorganize(on); save() }
    func setBatterySaver(_ on: Bool) { preferences.batterySaver = on; save() }
    func setRecoveryCopy(_ on: Bool) {
        preferences.recoveryCopy = on
        journal?.setEnabled(on)
        if !on {
            Task { [journal, store = deps.store] in
                await journal?.settle()
                try? store?.deleteRecovery()
            }
            recoverable.removeAll(); recovery = nil
        }
        save()
    }
    private func save() {
        do { try deps.store?.save(preferences) } catch { notice = SessionFailure.storage.localizedDescription }
        configure()
    }

    /// Where structuring sends text, for the disclosure line.
    var structureDisclosure: String {
        guard let health else { return "Chirp checks your Mac when you record." }
        guard health.correctionAvailable else { return "Your Mac has clean-up off, so notes stay a transcript." }
        if health.notesStructure != true { return "Your Mac's chirp-server is too old to structure notes. Update it." }
        if health.correctionLeavesMachine == false { return "Structuring runs on your Mac." }
        if let host = health.correctionHost, !host.isEmpty { return "Structuring sends the transcript to \(host). Audio stays on your Mac." }
        return "The structuring destination is unknown, so structuring is off."
    }
    var structureCanEnable: Bool {
        guard let health, health.correctionAvailable, health.notesStructure == true else { return false }
        return health.correctionLeavesMachine == false || health.correctionHost?.isEmpty == false
    }

    func refreshHealth() async {
        guard let config = deps.server() else { health = nil; configure(); return }
        serverBox.config = config
        guard let fresh = try? await deps.fetchHealth(config, deps.http), fresh.ok else { return }
        health = fresh
        recorder.serverAvailable()
        configure()
    }

    /// The `start` options and the structuring switch for this server (the Mac's hidden `live_notes` style when it has one).
    private func configure() {
        let h = health
        let correction = h.map(deps.correctionAllowed) ?? false
        recorder.options = h?.notesCorrection == true
            ? StartOptions(client: "ios", correction: correction, correctionProfile: CorrectionProfile.liveNotesID, wordTimings: true)
            : StartOptions(client: "ios", correction: correction, correctionProfile: CorrectionProfile.defaultID, wordTimings: true)
        recorder.serverHost = deps.server()?.host ?? ""
        recorder.configureStructuring(enabled: preferences.structureEnabled(health: h), health: h)
    }

    // MARK: app lifecycle

    private func observeApp() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setBackground(true) }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setBackground(false) }
        })
    }

    /// Locked or behind another app. With battery saver the screen is not updated meanwhile; the recorder, the journal and
    /// the Live Activity's state go on.
    func setBackground(_ value: Bool) {
        guard value != background else { return }
        background = value
        if !value {
            recorder.serverAvailable()
            Task { await refreshHealth() }
        }
        sync()
    }

    private var quiet: Bool { background && preferences.batterySaver }

    // MARK: sync

    func sync() {
        let changes = recorder.takePendingChanges()
        snaps.record(changes, from: textBefore, result: recorder.document.text, at: Date())
        textBefore = recorder.document.text
        let state = recorder.state
        let leftCapture = state != lastState && !state.isCapturing
        if state != lastState {
            lastState = state
            if !state.isCapturing { deps.audio.stop() }
            if state != .paused { pausedForInterruption = false }
        }
        journal?.update(recorder.document, elapsed: recorder.elapsed, urgent: !changes.isEmpty || leftCapture)
        updateActivity()
        setTicking(state.isCapturing && !quiet)
        if quiet { skippedUpdates += 1; return }
        publish()
    }

    private func publish() {
        state = recorder.state
        document = recorder.document
        structuring = recorder.structuring
        reorganize = recorder.reorganizeStatus
        connection = recorder.connection
        elapsed = recorder.elapsed
        pauseReason = recorder.pauseReason
        debugRetention = recorder.debugRetention || health?.debugRetention == true
        snapshots = snaps
    }

    private func setTicking(_ on: Bool) {
        guard on != (stopTick != nil) else { return }
        stopTick?(); stopTick = nil
        guard on else { return }
        stopTick = deps.startTicker { [weak self] in
            guard let self, !self.quiet else { return }
            self.elapsed = self.recorder.elapsed
            self.connection = self.recorder.connection
        }
    }

    // MARK: Live Activity

    private var activityState: ChirpNotesActivityAttributes.ContentState? {
        let status: ChirpNotesActivityAttributes.Status
        switch recorder.state {
        case .starting, .recording:
            if case .offline = recorder.connection { status = .offline } else { status = .recording }
        case .paused: status = .paused
        case .stopping: status = .finishing
        default: return nil
        }
        let elapsed = recorder.elapsed
        // Whole seconds, so an update with the same state does not move the start date by a fraction.
        let started = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - elapsed).rounded())
        return .init(status: status, startedAt: started, elapsed: elapsed.rounded(.down),
                     debugRetention: recorder.debugRetention || health?.debugRetention == true)
    }

    private func beginActivity() {
        guard !activityLive, let state = activityState else { return }
        do {
            try deps.activity.begin(state)
            activityLive = true
            lastActivity = state
        } catch { notice = "Live Activities are off for Chirp, so the lock screen has no controls. Recording continues." }
    }

    /// The activity changes with the state only (status or debug banner), never per segment: the system counts the time.
    private func updateActivity() {
        guard activityLive else { return }
        guard let state = activityState else {
            activityLive = false; lastActivity = nil
            Task { await deps.activity.end() }
            return
        }
        guard state.status != lastActivity?.status || state.debugRetention != lastActivity?.debugRetention else { return }
        lastActivity = state
        Task { await deps.activity.update(state) }
    }
}

extension LiveNotesController {
    /// The app's controller, built once on the coordinator's pairing and preferences.
    static func current(for coordinator: SessionCoordinator) -> LiveNotesController {
        if let instance { return instance }
        let made: LiveNotesController
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--chirp-ui-test") {
            made = .synthetic(coordinator: coordinator)
        } else {
            made = .production(coordinator: coordinator)
        }
        #else
        made = .production(coordinator: coordinator)
        #endif
        coordinator.otherCaptureActive = { [weak made] in made?.isActive ?? false }
        instance = made
        return made
    }

    private static func production(coordinator: SessionCoordinator) -> LiveNotesController {
        let config = SharedConfiguration(bundle: .main)
        var store: NotesStore?
        do { store = try NotesStore.production(secrets: KeychainSecretStore(accessGroup: config.keychainAccessGroup)) } catch {}
        var audio: any NotesAudio = NotesMicrophone()
        #if DEBUG
        if let file = SimulatorNotesAudio.fromArguments() { audio = file }
        #endif
        let deps = Dependencies(
            server: { [weak coordinator] in coordinator?.services.flatMap { try? $0.pairing.load() } },
            correctionAllowed: { [weak coordinator] in coordinator?.preferences.permitsCorrection(health: $0) ?? false },
            otherCaptureActive: { [weak coordinator] in coordinator?.armed ?? false },
            http: SafeHTTPSession.make(), audio: audio,
            requestPermission: { await AVAudioApplication.requestRecordPermission() },
            activity: .system, store: store)
        let made = LiveNotesController(deps)
        if store == nil { made.notice = "Protected storage unavailable, so no recovery copy is kept." }
        return made
    }
}
