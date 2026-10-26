import ChirpCore
import ChirpIOSCore
import Foundation
import Testing
@testable import ChirpIOS

actor TestVoiceLibrary {
    var library = SavedVoices(enabled: true, model: "synthetic", voices: [])
    var actions: [VoiceLibraryAction] = []
    var failure: VoiceLibraryError?
    func read() -> SavedVoices { library }
    func requests() -> [VoiceLibraryAction] { actions }
    func fail(_ error: VoiceLibraryError?) { failure = error }
    func perform(_ action: VoiceLibraryAction) throws -> SavedVoices {
        actions.append(action)
        if let failure { throw failure }
        library.voice = nil
        switch action {
        case .remember(let name, _, let id):
            let voice = SavedVoice(id: id ?? "0123456789abcdef", name: name, seconds: 25, created: .distantPast, updated: .distantPast)
            library.voices.removeAll { $0.id == voice.id }; library.voices.append(voice); library.voice = voice
        case .rename(let id, let name):
            if let i = library.voices.firstIndex(where: { $0.id == id }) { library.voices[i].name = name }
        case .forget(let id): library.voices.removeAll { $0.id == id }
        case .forgetAll: library.voices = []
        case .enable: library.enabled = true
        case .disable(let forget): library.enabled = false; if forget { library.voices = [] }
        case .importVoice: break
        }
        return library
    }
}

@Suite("Saved voices", .serialized) @MainActor
struct SavedVoicesTests {
    let helpers = LiveNotesControllerTests()
    private var health: Health {
        var h = LiveNotesController.syntheticHealth; h.speakerVoices = true; return h
    }
    @Test func namingRemembersFromTheRecordersRealSessionAndUpdateReusesTheVoice() async throws {
        let server = TestVoiceLibrary()
        let f = try helpers.fixture(voiceLibrary: server, health: health); defer { f.clean() }
        await f.notes.refreshHealth(); await f.notes.record(); await f.notes.stop()
        try await helpers.eventually("two labelled people") { f.notes.document.namableSpeakers.count == 2 }
        f.notes.renameSpeaker(1, to: "Maya", replaceInNotes: true)
        try await helpers.eventually("remembered") { f.notes.savedVoices?.voices.count == 1 }
        let action = try #require(await server.requests().first)
        guard case .remember(let name, .note(let session, let generation, let speaker), nil) = action else { Issue.record("Expected session remember"); return }
        #expect(name == "Maya" && generation == "synthetic-generation" && speaker == 0)
        #expect(f.values.starts.contains { $0.contains(session) })
        #expect(f.notes.rememberedVoiceNotice == "Maya" && f.notes.preferences.voiceNoticeShown)
        f.notes.rememberedVoiceNotice = nil
        f.notes.updateVoice(1)
        // Await the request count rather than relying on a previous response.
        for _ in 0..<100 where await server.requests().count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await server.requests().last == .remember(name: "Maya", from: .note(session: session, generation: generation, speaker: speaker), voice: "0123456789abcdef"))
        #expect(f.notes.rememberedVoiceNotice == nil)
    }

    @Test func tooShortKeepsTheNameAndRetriesOnTheNextLabelledSegment() async throws {
        let server = TestVoiceLibrary(); await server.fail(.tooShort)
        let f = try helpers.fixture(voiceLibrary: server, health: health); defer { f.clean() }
        await f.notes.refreshHealth(); await f.notes.record(); await f.notes.stop()
        try await helpers.eventually("labels") { f.notes.document.namableSpeakers.count == 2 }
        f.notes.renameSpeaker(1, to: "Maya", replaceInNotes: false)
        try await helpers.eventually("short") { f.notes.voicesError?.contains("20 seconds") == true }
        #expect(f.notes.document.roster.displayName(1) == "Maya")
        await server.fail(nil)
        f.notes.recorder.onServerSpeakers?(ServerSpeakers(generation: "synthetic-generation", turns: [ServerTurn(speaker: 0, start: 0, text: "More speech.")]), "synthetic-session")
        try await helpers.eventually("remembered later") { f.notes.savedVoices?.voices.count == 1 }
    }

    @Test func realStreamMatchesNameBeforeTheStructuringRequestIsBuilt() async throws {
        let server = TestVoiceLibrary()
        let match = ServerVoiceMatch(speaker: 0, voice: "0123456789abcdef", name: "Maya")
        let f = try helpers.fixture(voiceLibrary: server, voiceMatches: [match], health: health); defer { f.clean() }
        await f.notes.refreshHealth(); await f.notes.record(); await f.notes.stop()
        try await helpers.eventually("structured with the matched name") { f.notes.document.text.contains("Maya:") }
        #expect(f.notes.recognisedVoice(1)?.voice == match.voice)
        #expect(await server.requests().isEmpty)
    }

    @Test func matchesAreNamedWithCheckAndNotXDoesNotForgetTheLibrary() async throws {
        let server = TestVoiceLibrary()
        let f = try helpers.fixture(voiceLibrary: server, health: health); defer { f.clean() }
        await f.notes.refreshHealth(); await f.notes.record(); await f.notes.stop()
        try await helpers.eventually("labels") { f.notes.document.namableSpeakers.count == 2 }
        let labels = ServerSpeakers(generation: "synthetic-generation", turns: [ServerTurn(speaker: 0, start: 0, text: "Speech.")],
                                   matches: [ServerVoiceMatch(speaker: 0, voice: "0123456789abcdef", name: "Maya")])
        f.notes.recorder.onServerSpeakers?(labels, "synthetic-session")
        #expect(f.notes.document.roster.displayName(1) == "Maya" && f.notes.recognisedVoice(1) != nil)
        f.notes.rejectVoice(1)
        f.notes.recorder.onServerSpeakers?(labels, "synthetic-session")
        #expect(f.notes.document.roster.displayName(1) == "Person 1" && f.notes.recognisedVoice(1) == nil)
        #expect(await server.requests().isEmpty)
    }

    @Test func savedVoiceActionsAreServerWideAndDoNotRenameExistingNotes() async throws {
        let server = TestVoiceLibrary()
        let f = try helpers.fixture(voiceLibrary: server, health: health); defer { f.clean() }
        await f.notes.refreshHealth()
        await f.notes.changeSavedVoices(.remember(name: "Maya", from: .note(session: "session", generation: "generation", speaker: 0)))
        await f.notes.changeSavedVoices(.rename(voice: "0123456789abcdef", name: "Theo"))
        #expect(f.notes.savedVoices?.voices.first?.name == "Theo" && f.notes.document.namedSpeakers.isEmpty)
        await f.notes.changeSavedVoices(.disable(forget: false))
        #expect(!f.notes.rememberVoices && f.notes.savedVoices?.voices.count == 1)
        await f.notes.changeSavedVoices(.enable)
        await f.notes.changeSavedVoices(.forget(voice: "0123456789abcdef"))
        #expect(f.notes.savedVoices?.voices.isEmpty == true)
        await f.notes.changeSavedVoices(.forgetAll)
        #expect(await server.read().voices.isEmpty)
    }

    @Test func namingWhileRememberingIsOffDoesNotQueueASaveWhenItIsEnabledLater() async throws {
        let server = TestVoiceLibrary()
        let f = try helpers.fixture(voiceLibrary: server, health: health); defer { f.clean() }
        await f.notes.refreshHealth(); await f.notes.changeSavedVoices(.disable(forget: false))
        await f.notes.record(); await f.notes.stop()
        try await helpers.eventually("labels") { f.notes.document.namableSpeakers.count == 2 }
        f.notes.renameSpeaker(1, to: "Maya", replaceInNotes: true)
        await f.notes.changeSavedVoices(.enable)
        f.notes.recorder.onServerSpeakers?(ServerSpeakers(generation: "synthetic-generation", turns: [ServerTurn(speaker: 0, start: 0, text: "More speech.")]), "session")
        // Let any wrongly queued request reach the fake server.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await server.requests() == [.disable(forget: false), .enable])
        #expect(f.notes.document.roster.displayName(1) == "Maya")
    }

    @Test func oldServersHideRememberAndNeverRequestTheLibrary() async throws {
        let server = TestVoiceLibrary()
        let f = try helpers.fixture(voiceLibrary: server); defer { f.clean() }
        await f.notes.refreshHealth()
        #expect(!f.notes.voicesAvailable && f.notes.savedVoices == nil)
        await f.notes.changeSavedVoices(.enable)
        #expect(await server.requests().isEmpty)
    }
}
