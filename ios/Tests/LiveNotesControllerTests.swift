import ChirpCore
import ChirpIOSCore
import Foundation
import Testing
@testable import ChirpIOS

@Suite("Live Notes", .serialized)
@MainActor
struct LiveNotesControllerTests {
    final class Values {
        var activity: [String] = []
        var copied: [String] = []
        var otherCapture = false
        var permission = true
        var activityEnabled = true
        var backgroundTasks = 0
    }
    @MainActor struct Fixture {
        let notes: LiveNotesController
        let audio: SyntheticNotesAudio
        let values: Values
        let store: NotesStore
        let root: URL
        func clean() { notes.recorder.cancel(); audio.stop(); try? FileManager.default.removeItem(at: root) }
        /// Journal files on disk (polling `recoverable()` would delete a write's temp file mid-write).
        var journalFiles: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: store.recoveryDirectory.path)) ?? []).filter { $0.hasSuffix(".json") }
        }
    }

    func fixture(root: URL? = nil, secrets: MemorySecretStore = MemorySecretStore(), health: Health = LiveNotesController.syntheticHealth) throws -> Fixture {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("chirp-notes-unit-" + UUID().uuidString)
        let store = try NotesStore(root: root, secrets: secrets)
        let values = Values(), audio = SyntheticNotesAudio()
        let deps = LiveNotesController.Dependencies(
            server: { ServerConfig(baseURL: URL(string: "https://synthetic.test.ts.net/chirp")!, token: "synthetic-only") },
            correctionAllowed: { _ in true },
            otherCaptureActive: { values.otherCapture },
            http: URLSession(configuration: .ephemeral),
            fetchHealth: { _, _ in health },
            makeStream: { _, options, _ in StreamSession(transport: SyntheticTransport(automatic: true), options: options) },
            structure: { _, _, request in LiveNotesController.syntheticStructure(request) },
            reorganize: { _, _, request in LiveNotesController.syntheticReorganize(request) },
            audio: audio, requestPermission: { values.permission },
            activity: NotesActivityControl(begin: { state in
                guard values.activityEnabled else { throw NotesLiveActivity.Unavailable.disabled }
                values.activity.append("begin:" + state.status.rawValue)
            }, update: { values.activity.append("update:" + $0.status.rawValue) }, end: { values.activity.append("end") }),
            store: store, copyText: { values.copied.append($0) }, startTicker: { _ in {} },
            backgroundTask: { _ in values.backgroundTasks += 1; return {} }, observeLifecycle: false)
        return Fixture(notes: LiveNotesController(deps), audio: audio, values: values, store: store, root: root)
    }

    func eventually(_ what: Comment, timeout: Duration = .seconds(5), _ check: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if check() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(check(), what)
    }

    @Test func recordsPausesResumesAndStopsWithTheLiveActivityFollowing() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        #expect(f.audio.isRunning && f.audio.starts == 1)
        #expect(f.values.activity == ["begin:recording"])
        try await eventually("partial") { f.notes.document.livePartial == "synthetic words" }

        await f.notes.pause()
        #expect(f.notes.state == .paused && !f.audio.isRunning)
        try await eventually("segment committed while paused") { f.notes.document.segments.count == 1 }
        try await eventually("structured") { f.notes.document.text.contains("## Synthetic notes") }
        #expect(f.notes.document.text.contains("- Synthetic words."))
        try await eventually("activity paused") { f.values.activity.last == "update:paused" }

        await f.notes.resume()
        try await eventually("recording again") { f.notes.state == .recording }
        #expect(f.audio.starts == 2)
        try await eventually("activity recording") { f.values.activity.last == "update:recording" }

        await f.notes.stop()
        try await eventually("stopped") { f.notes.state == .stopped }
        #expect(!f.audio.isRunning && f.values.backgroundTasks == 1)
        try await eventually("activity ended") { f.values.activity.last == "end" }
        #expect(f.values.activity.contains("update:finishing"))
        #expect(f.notes.document.segments.count == 2)
        #expect(f.notes.document.transcriptParagraphs.first?.text(raw: true) == "synthetic words")
        f.notes.copy()
        #expect(f.values.copied.first?.contains("Synthetic words.") == true)
    }

    @Test func notesAndAKeyboardSessionNeverShareTheMicrophone() async throws {
        let f = try fixture(); defer { f.clean() }
        f.values.otherCapture = true
        await f.notes.record()
        #expect(f.notes.state == .idle && !f.audio.isRunning && f.notes.notice.contains("keyboard session"))
        f.values.otherCapture = false
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        let coordinator = SessionCoordinator(audio: SyntheticAudio(), production: false)
        coordinator.otherCaptureActive = { f.notes.isActive }
        await #expect(throws: SessionFailure.notesRecording) { try await coordinator.armSession() }
    }

    @Test func microphoneDeniedOrLiveActivitiesOff() async throws {
        let f = try fixture(); defer { f.clean() }
        f.values.permission = false
        await f.notes.record()
        #expect(f.notes.state == .idle && f.notes.notice == SessionFailure.permission.localizedDescription)
        f.values.permission = true; f.values.activityEnabled = false
        await f.notes.record()
        try await eventually("recording without a Live Activity") { f.notes.state == .recording }
        #expect(f.notes.notice.contains("Live Activities are off"))
    }

    @Test func batterySaverSkipsScreenUpdatesWhileLockedButNotTheWork() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        f.notes.setBackground(true)
        await f.notes.pause()
        try await eventually("segment committed in the recorder") { f.notes.recorder.document.segments.count == 1 }
        #expect(f.notes.state == .recording, "the screen state is not updated while locked")
        #expect(f.notes.document.segments.isEmpty && f.notes.skippedUpdates > 0)
        try await eventually("the Live Activity still follows the state") { f.values.activity.last == "update:paused" }
        f.notes.setBackground(false)
        #expect(f.notes.state == .paused && f.notes.document.segments.count == 1)

        f.notes.setBatterySaver(false)
        f.notes.setBackground(true)
        await f.notes.resume()
        try await eventually("published while in the background without battery saver") { f.notes.state == .recording }
    }

    @Test func aCallPausesAndResumesWhenIOSSaysSo() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        f.audio.event?(.interrupted)
        try await eventually("paused") { f.notes.state == .paused }
        #expect(f.notes.pauseReason == LiveNotesController.interruptedReason && !f.audio.isRunning)
        f.audio.event?(.resumable)
        try await eventually("resumed") { f.notes.state == .recording }
        #expect(f.audio.starts == 2)
        // A user pause is never resumed by iOS.
        await f.notes.pause()
        f.audio.event?(.resumable)
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.notes.state == .paused)
    }

    @Test func organizeAndUndoOrganize() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        await f.notes.stop()
        try await eventually("structured and stopped") { f.notes.state == .stopped && f.notes.document.text.contains("Synthetic words.") }
        let typed = f.notes.document.text + "\n- Apples go on the list before the spring fair opens on the village green"
        f.notes.edit(typed)
        #expect(f.notes.document.text == typed)
        f.notes.organize()
        try await eventually("organized", timeout: .seconds(10)) { f.notes.canUndoOrganize }
        #expect(f.notes.document.text != typed)
        #expect(f.notes.undoOrganize())
        #expect(f.notes.document.text == typed && !f.notes.canUndoOrganize)
    }

    @Test func anUnsavedSessionIsOfferedAgainAndKeptOrDiscarded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-notes-unit-" + UUID().uuidString)
        let secrets = MemorySecretStore()
        let first = try fixture(root: root, secrets: secrets)
        await first.notes.record()
        try await eventually("recording") { first.notes.state == .recording }
        await first.notes.stop()
        try await eventually("stopped") { first.notes.state == .stopped }
        try await eventually("journal written") { !first.journalFiles.isEmpty }
        let text = first.notes.recorder.document.text
        first.notes.recorder.cancel(); first.audio.stop()

        let second = try fixture(root: root, secrets: secrets); defer { second.clean() }
        #expect(second.notes.recovery?.document.text == text)
        second.notes.keepRecovered()
        #expect(second.notes.document.text == text && second.notes.state == .stopped && second.notes.recovery == nil)
        second.notes.didExport()
        try await eventually("a saved document has no recovery copy") { second.journalFiles.isEmpty }
    }

    @Test func turningTheRecoveryCopyOffDeletesItAndItsKey() async throws {
        let secrets = MemorySecretStore()
        let f = try fixture(secrets: secrets); defer { f.clean() }
        f.notes.edit("A line typed by hand")
        try await eventually("journal written") { !f.journalFiles.isEmpty }
        f.notes.setRecoveryCopy(false)
        try await eventually("deleted") {
            (try? FileManager.default.contentsOfDirectory(atPath: f.store.recoveryDirectory.path).isEmpty) == true
                && (try? secrets.read(account: "notes-recovery-key")) == nil
        }
        #expect(try f.store.loadPreferences().recoveryCopy == false)
    }

    @Test func structuringNeedsConsentForAnOffMacDestination() async throws {
        let remote = Health(engine: "e", ready: true, correction: "available", correctionLeavesMachine: true,
                            correctionHost: "api.example.test", notesStructure: true, notesReorganize: true)
        let f = try fixture(health: remote); defer { f.clean() }
        await f.notes.refreshHealth()
        #expect(f.notes.structuring == .off(.disabled))
        #expect(f.notes.structureDisclosure.contains("api.example.test"))
        f.notes.setStructure(true)
        #expect(f.notes.preferences.structureConsentHost == "api.example.test")
        #expect(f.notes.structuring == .idle)
    }

    @Test func aLiveActivityButtonActsOnlyOnALiveSession() async throws {
        let f = try fixture(); defer { f.clean() }
        #expect(await f.notes.perform(.stop) == "Live Notes is not recording.")
        #expect(await f.notes.perform(.start) == "Recording notes.")
        try await eventually("recording") { f.notes.state == .recording }
        #expect(await f.notes.perform(.togglePause) == "Live Notes paused. Microphone off.")
        #expect(await f.notes.perform(.togglePause) == "Live Notes recording.")
        #expect(await f.notes.perform(.stop) == "Live Notes stopped. Your notes are in Chirp.")
    }
}
