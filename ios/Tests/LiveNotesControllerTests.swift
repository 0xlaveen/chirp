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
        /// Every socket the recorder opened, oldest first (their `sent` messages are the `start`s).
        var transports: [SyntheticTransport] = []
        let speakerCalls = SpeakerCalls()
        var speakerRequests: [SpeakersModelAction] { speakerCalls.actions }
        var starts: [String] {
            transports.flatMap { $0.sent }.compactMap { if case .string(let text) = $0, text.contains(#""type":"start""#) { text } else { nil } }
        }
    }
    /// The model requests the controller made (its closure is `@Sendable`, so the record needs a lock).
    final class SpeakerCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [SpeakersModelAction] = []
        var actions: [SpeakersModelAction] { lock.withLock { list } }
        func add(_ action: SpeakersModelAction) { lock.withLock { list.append(action) } }
    }
    @MainActor struct Fixture {
        let notes: LiveNotesController
        let audio: SyntheticNotesAudio
        let values: Values
        let store: NotesStore
        let root: URL
        func clean() { notes.shutdown(); audio.stop(); try? FileManager.default.removeItem(at: root) }
        /// Journal files on disk (polling `recoverable()` would delete a write's temp file mid-write).
        var journalFiles: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: store.recoveryDirectory.path)) ?? []).filter { $0.hasSuffix(".json") }
        }
    }

    func fixture(root: URL? = nil, secrets: MemorySecretStore = MemorySecretStore(), health: Health = LiveNotesController.syntheticHealth,
                 reorganize: @escaping @Sendable (NotesReorganizeRequest) async throws -> NotesReorganizeResponse = { LiveNotesController.syntheticReorganize($0) },
                 structure: @escaping @Sendable (NotesStructureRequest) async throws -> NotesStructureResponse = { LiveNotesController.syntheticStructure($0) }) throws -> Fixture {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("chirp-notes-unit-" + UUID().uuidString)
        let store = try NotesStore(root: root, secrets: secrets)
        let values = Values(), audio = SyntheticNotesAudio()
        let deps = LiveNotesController.Dependencies(
            server: { ServerConfig(baseURL: URL(string: "https://synthetic.test.ts.net/chirp")!, token: "synthetic-only") },
            correctionAllowed: { _ in true },
            otherCaptureActive: { values.otherCapture },
            http: URLSession(configuration: .ephemeral),
            fetchHealth: { _, _ in health },
            makeStream: { _, options, _ in
                let transport = SyntheticTransport(automatic: true)
                values.transports.append(transport)
                return StreamSession(transport: transport, options: options)
            },
            structure: { _, _, request in try await structure(request) },
            reorganize: { _, _, request in try await reorganize(request) },
            speakersModel: { [calls = values.speakerCalls] _, _, action in
                calls.add(action)
                return SpeakersModel(state: .downloading)
            },
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

    @Test func stoppedNotesPersistAcrossRelaunchAndExportDoesNotDeleteThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-notes-unit-" + UUID().uuidString)
        let secrets = MemorySecretStore()
        let first = try fixture(root: root, secrets: secrets)
        await first.notes.record()
        try await eventually("recording") { first.notes.state == .recording }
        await first.notes.stop()
        await first.notes.settleJournal()
        let id = first.notes.document.id, text = first.notes.document.text
        #expect(first.notes.entries.map(\.id) == [id])
        first.notes.didExport()
        await first.notes.settleJournal()
        first.notes.recorder.cancel(); first.audio.stop()

        let second = try fixture(root: root, secrets: secrets); defer { second.clean() }
        await second.notes.ready()
        #expect(second.notes.entries.map(\.id) == [id])
        await second.notes.open(id)
        #expect(second.notes.document.text == text && second.notes.state == .stopped)
        #expect(second.notes.entries.first?.recovered == false)
    }

    @Test func explicitOptOutStopsNewWritesAndCanBeEnabledAgain() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.ready()
        f.notes.setKeepNotes(false)
        f.notes.edit("A private transient thought")
        await f.notes.settleJournal()
        #expect(f.notes.entries.isEmpty)
        #expect(try f.store.loadPreferences().keepNotes == false)
        f.notes.setKeepNotes(true)
        await f.notes.settleJournal()
        #expect(f.notes.entries.count == 1)
    }

    @Test func browsingKeepsRecordingPinnedAndContinueAppendsABoundary() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.ready()
        f.notes.edit("## Older note\n- [ ] Review")
        await f.notes.settleJournal()
        let older = f.notes.document.id
        await f.notes.newRecording()
        try await eventually("recording") { f.notes.state == .recording }
        let active = f.notes.document.id
        await f.notes.open(older)
        #expect(f.notes.document.id == older && f.notes.recordingID == active && f.notes.isActive)
        #expect(f.audio.isRunning)
        await f.notes.delete([active])
        #expect(f.notes.entries.contains { $0.id == active })
        await f.notes.stop()
        #expect(!f.notes.isActive && f.notes.document.id == older)
        await f.notes.open(active)
        let elapsed = f.notes.elapsed
        await f.notes.record()
        try await eventually("continued") { f.notes.state == .recording }
        #expect(f.notes.document.sessions.count == 2)
        #expect(f.notes.document.sessions.last?.offset == elapsed)
        await f.notes.stop()
        await f.notes.delete([older])
        #expect(f.notes.recentlyDeleted.map(\.id) == [older])
        await f.notes.restore([older])
        #expect(f.notes.entries.contains { $0.id == older })
    }

    @Test func explicitHistoryHandoffCreatesOrAppendsWithoutMovingTheRecording() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        let active = f.notes.document.id
        let destination = try #require(await f.notes.addToNote("A thought from dictation"))
        #expect(destination != active && f.notes.recordingID == active && f.audio.isRunning)
        #expect(f.notes.requestedSelection == destination)
        #expect(await f.notes.addToNote("A second thought", id: destination) == destination)
        #expect(f.notes.document.text == "A thought from dictation\n\nA second thought")
        #expect(try await f.store.libraryStore.record(destination).document.text == f.notes.document.text)
        #expect(await f.notes.addToNote("  ") == nil)
        await f.notes.stop()
    }

    actor OrganizeGate {
        private var continuation: CheckedContinuation<NotesReorganizeResponse, Never>?
        private var released = false
        private var response: NotesReorganizeResponse { NotesReorganizeResponse(markdown: "## Organized original\n- First note only", reorganized: true, changed: true) }
        func respond(_ request: NotesReorganizeRequest) async -> NotesReorganizeResponse {
            if released { return response }
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume(returning: response)
            continuation = nil
        }
    }

    @Test func lateOrganizeUpdatesItsOriginalNoteWhileAnotherIsOpen() async throws {
        let gate = OrganizeGate()
        let f = try fixture(reorganize: { await gate.respond($0) }); defer { f.clean() }
        await f.notes.ready()
        await f.notes.refreshHealth()
        f.notes.setAutoReorganize(false)
        f.notes.edit("## Original\n- We reviewed the next quarter budget and agreed to send the updated contract on Thursday.")
        await f.notes.settleJournal()
        let original = f.notes.document.id
        let originalRecorder = f.notes.recorder
        f.notes.organize()
        try await eventually("organize pending") { f.notes.reorganize.isRunning }
        f.notes.newNotes()
        f.notes.edit("## Other\n- Keep exactly these words")
        let other = f.notes.document
        await gate.release()
        try await eventually("original organize finished") { !originalRecorder.reorganizeStatus.isRunning }
        await f.notes.settleJournal()
        #expect(f.notes.document.id == other.id && f.notes.document.text == other.text)
        #expect(try await f.store.libraryStore.record(original).document.text.contains("Organized original"))
    }

    actor StructureGate {
        private var continuation: CheckedContinuation<NotesStructureResponse, Never>?
        private var released = false
        private var response: NotesStructureResponse { NotesStructureResponse(markdown: "## Structured original\n- Original recording only", structured: true) }
        func respond(_ request: NotesStructureRequest) async -> NotesStructureResponse {
            if released { return response }
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(returning: response); continuation = nil }
    }

    @Test func lateStructureUpdatesThePausedRecordingWhileAnotherNoteIsEdited() async throws {
        let gate = StructureGate()
        let f = try fixture(structure: { await gate.respond($0) }); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        let original = f.notes.recorder, id = f.notes.document.id
        await f.notes.pause()
        try await eventually("structure pending") { original.structuring == .running }
        f.notes.newNotes()
        f.notes.edit("## Another thought\n- Keep this note unchanged")
        let other = f.notes.document
        await gate.release()
        try await eventually("original structured") { original.document.text.contains("Structured original") }
        await f.notes.settleJournal()
        #expect(f.notes.document == other)
        #expect(f.notes.recordingID == id && f.notes.isActive)
        #expect(try await f.store.libraryStore.record(id).document.text.contains("Original recording only"))
        await f.notes.stop()
    }

    @Test func audioIsOptInAndStoredAfterItsSegment() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        await f.notes.stop()
        #expect(f.notes.totalAudioBytes == 0)
        f.notes.setKeepAudio(true)
        await f.notes.record()
        try await eventually("recording again") { f.notes.state == .recording }
        try await Task.sleep(for: .milliseconds(250))
        await f.notes.stop()
        await f.notes.settleJournal()
        #expect(f.notes.totalAudioBytes > 0)
        let record = try await f.store.libraryStore.record(f.notes.document.id)
        let reference = try #require(record.document.audio.first)
        #expect(reference.id == 1)
        #expect(try await f.notes.audioData(segment: reference.id)?.isEmpty == false)
        await f.notes.deleteAudio()
        #expect(f.notes.totalAudioBytes == 0 && !f.notes.document.text.isEmpty)
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

    // MARK: speaker labels (#201)

    private func speakerHealth(_ state: SpeakersModel.State?, speakers: Bool = true) -> Health {
        var h = LiveNotesController.syntheticHealth
        h.notesSpeakers = speakers ? true : nil
        h.speakersModel = state.map { SpeakersModel(state: $0) }
        return h
    }

    @Test func speakerLabelsAreOffByDefaultAndStartAsksForNone() async throws {
        let f = try fixture(health: speakerHealth(.ready)); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        await f.notes.stop()
        #expect(!f.notes.labelSpeakers && f.notes.speakersAvailable)
        #expect(!f.values.starts.isEmpty && f.values.starts.allSatisfy { !$0.contains("speakers") })
        #expect(f.notes.document.segments.allSatisfy { $0.turns == nil })
    }

    @Test func turningLabelsOnAsksBeforeTheDownloadAndDecliningFetchesNothing() async throws {
        let f = try fixture(health: speakerHealth(.notDownloaded)); defer { f.clean() }
        await f.notes.refreshHealth()
        f.notes.setLabelSpeakers(true, from: .note)
        #expect(f.notes.speakerConsent == .note && !f.notes.labelSpeakers && f.values.speakerRequests.isEmpty)
        f.notes.dismissSpeakerConsent()
        #expect(f.notes.speakerConsent == nil && !f.notes.labelSpeakers && f.values.speakerRequests.isEmpty)
        f.notes.setLabelSpeakers(true)
        #expect(f.notes.speakerConsent == .settings)
        f.notes.confirmSpeakerDownload()
        try await eventually("download requested") { f.values.speakerRequests == [.download] }
        #expect(f.notes.speakerConsent == nil && f.notes.labelSpeakers && f.notes.recorder.labelSpeakers)
        #expect(try f.store.loadPreferences().labelSpeakers)
    }

    @Test func aMacThatHasTheModelTurnsLabelsOnWithoutAsking() async throws {
        let f = try fixture(health: speakerHealth(.ready)); defer { f.clean() }
        await f.notes.refreshHealth()
        f.notes.setLabelSpeakers(true)
        #expect(f.notes.speakerConsent == nil && f.notes.labelSpeakers && f.values.speakerRequests.isEmpty)
        f.notes.setLabelSpeakers(false)
        #expect(!f.notes.labelSpeakers && !f.notes.recorder.labelSpeakers)
    }

    @Test func anOlderServerNeverGetsAskedForLabels() async throws {
        let f = try fixture(health: speakerHealth(nil, speakers: false)); defer { f.clean() }
        var p = try f.store.loadPreferences(); p.labelSpeakers = true; try f.store.save(p)
        await f.notes.refreshHealth()
        #expect(!f.notes.speakersAvailable && !f.notes.recorder.labelSpeakers)
        #expect(f.notes.speakerNote == nil)   // the preference was loaded at launch, the note is for the transcript
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        await f.notes.stop()
        #expect(f.values.starts.allSatisfy { !$0.contains("speakers") })
    }

    @Test func labelledNotesKeepTwoPeopleThroughRenameMergeSeparateAndTheSealedLibrary() async throws {
        let f = try fixture(health: speakerHealth(.ready)); defer { f.clean() }
        await f.notes.refreshHealth()
        f.notes.setLabelSpeakers(true)
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        await f.notes.stop()
        try await eventually("labelled segment") { f.notes.document.segments.contains { $0.turns?.count == 2 } }
        #expect(f.values.starts.allSatisfy { $0.contains(#""speakers":{"session":""#) })
        let document = f.notes.document, segment = try #require(document.segments.first { $0.turns != nil })
        #expect(segment.turns?.map(\.person) == [1, 2] && document.speakerCount == 2)
        try await eventually("structured with names") { f.notes.document.text.contains("Person 2: Second voice.") }

        f.notes.renameSpeaker(2, to: "Maya", replaceInNotes: true)
        #expect(f.notes.document.roster.displayName(2) == "Maya")
        #expect(f.notes.document.text.contains("Maya: Second voice.") && !f.notes.document.text.contains("Person 2"))
        #expect(f.notes.markdown.contains("Maya:"))

        f.notes.mergeSpeaker(2, into: 1)
        #expect(f.notes.document.roster.displayName(2) == "Person 1" && f.notes.document.speakerCount == 1)
        f.notes.separateSpeaker(2)
        #expect(f.notes.document.roster.displayName(2) == "Maya" && f.notes.document.speakerCount == 2)

        // Labels and names are inside the sealed note, and nothing but text is there.
        await f.notes.settleJournal()
        let stored = try await f.store.libraryStore.record(f.notes.document.id).document
        #expect(stored.segments.compactMap(\.turns) == f.notes.document.segments.compactMap(\.turns))
        #expect(stored.roster.displayName(2) == "Maya" && stored.roster.displayName(1) == "Person 1")
    }
}
