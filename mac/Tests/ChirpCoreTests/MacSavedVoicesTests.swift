import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// A fake server, exercising the same client boundary as the live Mac. All fixtures are synthetic.
actor MacVoiceServer {
    static let first = SavedVoice(id: "0123456789abcdef", name: "Maya", seconds: 24,
                                 created: Date(timeIntervalSince1970: 0), updated: Date(timeIntervalSince1970: 100))
    var library: SavedVoices
    var actions: [VoiceLibraryAction] = []
    var requests: [[VoiceClip]] = []
    var preparations = 0
    var matches: [IdentifiedVoice] = []
    var failure: VoiceLibraryError?
    var identifyGate: VoiceTestGate?
    var actionGate: VoiceTestGate?

    init(voices: [SavedVoice] = [first], enabled: Bool = true) {
        library = SavedVoices(enabled: enabled, model: "server-model", voices: voices)
    }
    nonisolated var client: VoiceLibraryClient {
        VoiceLibraryClient(list: { await self.library }, action: { try await self.perform($0) }, identify: { try await self.identify($0) }, prepare: { await self.prepared() })
    }
    func prepared() { preparations += 1 }
    func setMatches(_ value: [IdentifiedVoice]) { matches = value }
    func fail(_ error: VoiceLibraryError?) { failure = error }
    func holdIdentify(_ gate: VoiceTestGate) { identifyGate = gate }
    func holdAction(_ gate: VoiceTestGate) { actionGate = gate }
    func identify(_ clips: [VoiceClip]) async throws -> [IdentifiedVoice] {
        requests.append(clips)
        if let identifyGate { try await identifyGate.wait() }
        if let failure { throw failure }
        return matches
    }
    func perform(_ action: VoiceLibraryAction) async throws -> SavedVoices {
        actions.append(action)
        if let actionGate { try await actionGate.wait() }
        if let failure { throw failure }
        library.voice = nil
        switch action {
        case .enable: library.enabled = true
        case .disable(let forget):
            library.enabled = false
            if forget { library.voices = [] }
        case .forgetAll: library.voices = []
        case .forget(let id): library.voices.removeAll { $0.id == id }
        case .rename(let id, let name):
            if let i = library.voices.firstIndex(where: { $0.id == id }) { library.voices[i].name = name }
        case .remember(let name, let source, let id):
            guard library.enabled else { throw VoiceLibraryError.disabled }
            guard case .audio(let pcm) = source else { throw VoiceLibraryError.badRequest }
            let seconds = Double(pcm.count) / 32_000
            guard seconds >= 20, pcm.count <= VoiceClip.maxBytes else { throw VoiceLibraryError.tooShort }
            let i = library.voices.firstIndex { $0.id == id }
            var voice = SavedVoice(id: id ?? "fedcba9876543210", name: name, seconds: seconds,
                                   created: Date(timeIntervalSince1970: 0), updated: Date(timeIntervalSince1970: 100))
            if let i { voice.seconds += library.voices[i].seconds; library.voices[i] = voice }
            else { library.voices.append(voice) }
            library.voice = voice
        case .importVoice(let name, _, let seconds, _):
            let voice = SavedVoice(id: "fedcba9876543210", name: name, seconds: seconds,
                                   created: Date(timeIntervalSince1970: 0), updated: Date(timeIntervalSince1970: 100))
            library.voices.append(voice); library.voice = voice
        }
        return library
    }
}

actor VoiceTestGate {
    enum Failure: Error { case timeout }
    private var continuation: CheckedContinuation<Void, Error>?
    private var observers: [CheckedContinuation<Bool, Never>] = []
    private var hasEntered = false
    private var released = false

    func wait() async throws {
        hasEntered = true
        for observer in observers { observer.resume(returning: true) }
        observers = []
        guard !released else { return }
        try await withCheckedThrowingContinuation { done in
            continuation = done
            Task { try? await Task.sleep(for: .seconds(5)); expire() }
        }
    }
    func entered() async -> Bool {
        if hasEntered { return true }
        return await withCheckedContinuation { done in
            observers.append(done)
            Task { try? await Task.sleep(for: .seconds(5)); expire() }
        }
    }
    private func expire() {
        released = true
        continuation?.resume(throwing: Failure.timeout); continuation = nil
        for observer in observers { observer.resume(returning: false) }
        observers = []
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct MacSavedVoicesTests {
    private func document() -> NotesDocument {
        var document = NotesDocument(text: "## Plan\n- Person 1 sends the schedule.")
        document.append(NotesSegment(id: 0, offset: 0, raw: "synthetic words", text: "Synthetic words."))
        document.attachSpeakers([.init(slot: 4, start: 0, text: "Synthetic."), .init(slot: 7, start: 2, text: "Words.")], toSegment: 0)
        return document
    }
    private func pcm(_ seconds: Int) -> Data { Data(repeating: 17, count: seconds * 32_000) }
    private func voices(_ server: MacVoiceServer, legacy: VoiceProfileStore = MemoryVoiceProfileStore()) async -> SpeakerVoices {
        let voices = SpeakerVoices(client: server.client, legacy: legacy)
        voices.configure(supported: true, server: "synthetic-server")
        await voices.refresh()
        return voices
    }
    private func harness(_ server: MacVoiceServer, seconds: Int = 10) async -> (NotesHarness, FakeDiarizer) {
        let harness = NotesHarness(voiceClient: server.client)
        let fake = FakeDiarizer(script: [])
        harness.recorder.restore(document(), elapsed: 25)
        // Recovery intentionally discards slot mappings. These fixtures represent a live session with its slots.
        harness.recorder.editSpeakers { $0 = document(); return [] }
        harness.recorder.speakers = fake
        harness.session.voices.configure(supported: true, server: "synthetic-server")
        await harness.session.voices.refresh()
        fake.setVoiceClips([4: pcm(seconds), 7: pcm(5)])
        harness.session.sync()
        #expect(fake.voiceClips[4]?.count == seconds * 32_000)
        #expect(harness.document.roster.existingPerson(forSlot: 4) == 1)
        return (harness, fake)
    }

    @Test func matchingRunsAtTenAndThirtySecondsWithOneToOneAndDeclineGuards() async {
        let server = MacVoiceServer()
        let voices = await voices(server), document = document()
        #expect(await voices.process(document, clips: [4: pcm(9)]).isEmpty)
        #expect(await server.requests.isEmpty)
        await server.setMatches([.init(person: 1, voice: MacVoiceServer.first.id, name: "Maya"),
                                 .init(person: 2, voice: MacVoiceServer.first.id, name: "Maya")])
        let matches = await voices.process(document, clips: [4: pcm(10), 7: pcm(10)])
        #expect(matches.count == 1 && matches.first?.person == 1)
        voices.accept(matches[0]); voices.decline(1)
        #expect(await voices.process(document, clips: [4: pcm(20)]).isEmpty)
        #expect(await voices.process(document, clips: [4: pcm(30)]).isEmpty)
        #expect(await server.requests.count == 2)
        voices.reset()
        #expect(await voices.process(document, clips: [4: pcm(10)]).count == 1)
    }

    @Test func namingBeforeEnoughSpeechWaitsAndUntickedRowsDoNotSave() async throws {
        let server = MacVoiceServer(voices: [])
        let voices = await voices(server)
        var document = document()
        document.renameSpeaker(1, to: "Theo"); document.renameSpeaker(2, to: "Maya")
        voices.name(1, "Theo"); voices.name(2, "Maya", remember: false)
        _ = await voices.process(document, clips: [4: pcm(19), 7: pcm(30)])
        #expect(await server.actions.isEmpty)
        _ = await voices.process(document, clips: [4: pcm(22), 7: pcm(30)])
        #expect(await server.actions.count == 1)
        #expect(await server.preparations == 1)
        #expect(voices.link(1)?.name == "Theo" && voices.link(2) == nil)
        #expect(voices.recognised.isEmpty)
        let saved = try #require(await server.actions.first)
        #expect(saved == .remember(name: "Theo", from: .audio(pcm(22)), voice: nil))
        // A later explicit update uses the voice id returned by the server, even with duplicate names.
        voices.name(1, "Theo")
        _ = await voices.process(document, clips: [4: pcm(22)])
        #expect(await server.actions.last == .remember(name: "Theo", from: .audio(pcm(22)), voice: voices.link(1)?.id))
    }

    @Test func theSessionAutoNamesForStructuringAndNotRestoresPersonWithoutForgetting() async {
        let server = MacVoiceServer()
        await server.setMatches([.init(person: 1, voice: MacVoiceServer.first.id, name: "Maya")])
        let (harness, fake) = await harness(server)
        await harness.session.waitForSavedVoices()
        #expect(harness.document.roster.displayName(1) == "Maya")
        #expect(harness.model.voices.recognised == [1])
        #expect(harness.document.labelledText(harness.document.segments[0]).contains("Maya:"))
        #expect(harness.document.exportMarkdown().contains("Maya"))
        harness.session.editSpeakers(.declineVoice(1))
        fake.setVoiceClips([4: pcm(30)])
        await harness.session.waitForSavedVoices()
        #expect(harness.document.roster.displayName(1) == "Person 1" && harness.model.voices.recognised.isEmpty)
        #expect(await server.library.voices.count == 1)
        #expect(await server.actions.isEmpty)
    }

    @Test func firstNoticeCanDisableRememberingAndIsAskedOnlyOnce() async {
        let server = MacVoiceServer(voices: [])
        let (harness, _) = await harness(server, seconds: 24)
        var notices = 0
        harness.session.confirmRememberVoice = { _, done in notices += 1; done(false) }
        harness.session.editSpeakers(.rename(1, to: "Theo"))
        await harness.session.waitForSavedVoices()
        #expect(notices == 1 && harness.prefs.notesVoiceNoticeShown)
        #expect(await server.actions == [.disable(forget: false)])
        #expect(!harness.session.voices.enabled)
        #expect(harness.document.roster.displayName(1) == "Theo")
    }

    @Test func lateRecognitionCannotRenameAnotherNoteOrAUserEditedPerson() async {
        for newNote in [false, true] {
            let server = MacVoiceServer(), gate = VoiceTestGate()
            await server.holdIdentify(gate)
            await server.setMatches([.init(person: 1, voice: MacVoiceServer.first.id, name: "Maya")])
            let (harness, _) = await harness(server)
            let pending = Task { await harness.session.waitForSavedVoices() }
            #expect(await gate.entered(), "The fake server did not receive its identify request within 5 seconds")
            if newNote { harness.session.reset() } else { harness.session.editSpeakers(.rename(1, to: "Theo")) }
            await gate.release(); await pending.value
            #expect(harness.document.roster.displayName(1) != "Maya")
            #expect(harness.model.voices.recognised.isEmpty)
        }
    }

    @Test func serverChangesAndSwitchOffDiscardInFlightRecognition() async {
        for switchOff in [false, true] {
            let server = MacVoiceServer(), gate = VoiceTestGate()
            let voices = await voices(server), document = document()
            await server.holdIdentify(gate)
            await server.setMatches([.init(person: 1, voice: MacVoiceServer.first.id, name: "Maya")])
            let task = Task { await voices.process(document, clips: [4: pcm(10)]) }
            #expect(await gate.entered(), "The fake server did not receive its identify request within 5 seconds")
            if switchOff { _ = await voices.perform(.disable(forget: false)) }
            else { voices.configure(supported: true, server: "other-synthetic-server") }
            await gate.release()
            #expect(await task.value.isEmpty && !voices.enabled)
        }
    }

    @Test func managementUsesServerActionsAndErrorsDoNotPretendToForget() async {
        let server = MacVoiceServer(), voices = await voices(server)
        #expect(await voices.perform(.rename(voice: MacVoiceServer.first.id, name: "Theo")))
        #expect(voices.profiles.first?.name == "Theo")
        await server.fail(.server(500, "synthetic-sensitive-detail"))
        #expect(!(await voices.perform(.forgetAll)))
        #expect(voices.profiles.count == 1 && voices.error?.contains("synthetic-sensitive-detail") == false)
        await server.fail(nil)
        #expect(await voices.perform(.disable(forget: false)) && !voices.enabled && voices.profiles.count == 1)
        #expect(await voices.perform(.enable) && voices.enabled)
        #expect(await voices.perform(.forget(voice: MacVoiceServer.first.id)) && voices.profiles.isEmpty)
        let unsupported = SpeakerVoices(client: server.client)
        #expect(!(await unsupported.perform(.enable)))
    }

    @Test func legacyImportDeletesOnlyAcknowledgedItemsAndNeverRepeatsAfterDeleteFailure() async throws {
        let old = VoiceProfile(name: "Maya", embedding: [Float](repeating: 0.012345, count: 256),
                               model: "wespeaker_v2@df2625a", seconds: 25)
        let store = FailingLegacyStore(old)
        let server = MacVoiceServer(voices: [])
        var imported = Set<UUID>()
        let voices = SpeakerVoices(client: server.client, legacy: store,
                                   imported: { imported.contains($0) }, acknowledgeImport: { imported.insert($0) })
        voices.configure(supported: true, server: "synthetic-server")
        await server.fail(.server(500, nil)); await voices.refresh()
        #expect(store.load() == [old] && imported.isEmpty)
        await server.fail(nil); await voices.refresh()
        #expect(imported == [old.id] && !store.load().isEmpty)
        store.allowDelete()
        await voices.refresh(); await voices.refresh()
        #expect(store.load().isEmpty)
        #expect(await server.actions.count == 2) // failed import, then acknowledged import; deletion retried alone
        #expect(voices.profiles.count == 1)
    }

    @Test func theSavedVoicesScreenAndRecognitionAreRenderedInBothThemes() throws {
        let names = ["settings-saved-voices-ready", "settings-saved-voices-empty", "settings-saved-voices-off",
                     "settings-saved-voices-unsupported", "settings-saved-voices-failed", "notes-voice-recognised"]
        for name in names {
            let scenario = try #require(Snapshots.allScenarios.first { $0.name == name })
            let light = try #require(Snapshots.png(scenario, appearance: .aqua))
            let dark = try #require(Snapshots.png(scenario, appearance: .darkAqua))
            #expect(light != dark)
            #expect(NSBitmapImageRep(data: light)!.pixelsWide > 400)
        }
        let view = VoiceProfilesView()
        var state = VoiceProfilesState()
        state.supported = true; state.enabled = true; state.profiles = [MacVoiceServer.first]
        view.apply(state)
        #expect(view.shown == state.profiles && view.toggle.state == .on && view.toggle.isEnabled)
        #expect(view.fittingSize.height < 500)
        state.busy = true; view.apply(state)
        #expect(!view.toggle.isEnabled)
        state.supported = false; view.apply(state)
        #expect(!view.toggle.isEnabled)
    }

    @Test func clipsFollowMergesStayBoundedAndNeverEnterPersistedNotesOrRequests() async throws {
        let server = MacVoiceServer(voices: [])
        let (harness, fake) = await harness(server, seconds: 24)
        let marker = "0.012345"
        harness.session.confirmRememberVoice = { _, done in done(true) }
        harness.session.editSpeakers(.rename(1, to: "Theo"))
        await harness.session.waitForSavedVoices()
        #expect(harness.session.voices.link(1)?.name == "Theo")
        #expect(await server.actions.count == 1)
        harness.session.journal.flush()
        await harness.session.journal.settle()
        let files = try #require(FileManager.default.enumerator(at: harness.journalDirectory, includingPropertiesForKeys: [.isRegularFileKey])).allObjects
        var stored = 0
        for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(!text.contains(marker) && !text.contains("embedding") && !text.contains("voiceClips"))
            stored += 1
        }
        #expect(stored > 0)
        let document = harness.document
        let request = try #require(document.nextStructureRequest())
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!payload.contains(marker) && !payload.contains("embedding") && !payload.contains("voiceClips"))
        #expect(VoiceLog.profiles(saved: 1, suggestions: 0) == "notes voices saved=1 suggestions=0")
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        #expect(!json.contains(marker) && !json.contains("embedding") && !json.contains("voiceClips"))
        #expect(!document.exportMarkdown().contains(marker))
        #expect(UserDefaults(suiteName: harness.suite)!.dictionaryRepresentation().values.allSatisfy { !String(describing: $0).contains(marker) })
        var merged = document
        merged.mergeSpeaker(2, into: 1)
        let clips = SpeakerVoices.personClips(merged, [4: pcm(24), 7: pcm(24)])
        #expect(clips.keys.sorted() == [1] && clips[1]?.count == VoiceClip.maxBytes)
        #expect(await harness.session.voices.perform(.disable(forget: true)))
        #expect(fake.voiceClips.isEmpty && harness.session.voices.profiles.isEmpty)
        #expect(VoiceProfilesText.detail(MacVoiceServer.first, locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!).contains("updated"))
    }
}

private final class FailingLegacyStore: VoiceProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [VoiceProfile]
    private var canDelete = false
    init(_ item: VoiceProfile) { items = [item] }
    func load() -> [VoiceProfile] { lock.withLock { items } }
    func save(_ profile: VoiceProfile) throws { throw VoiceLibraryError.unavailable }
    func allowDelete() { lock.withLock { canDelete = true } }
    func delete(_ id: UUID) throws {
        try lock.withLock {
            guard canDelete else { throw VoiceLibraryError.unavailable }
            items.removeAll { $0.id == id }
        }
    }
    func deleteAll() throws { throw VoiceLibraryError.unavailable }
}
