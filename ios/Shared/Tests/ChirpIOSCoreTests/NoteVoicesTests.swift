import ChirpCore
import Foundation
import Testing
@testable import ChirpIOSCore

@Suite struct NoteVoicesTests {
    private func document() -> NotesDocument {
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 0, raw: "hello there", text: "Hello there."))
        d.attachServerTurns([ServerTurn(speaker: 0, start: 0, text: "Hello there.")], generation: "generation", toSegment: 0)
        return d
    }
    private var labels: ServerSpeakers {
        ServerSpeakers(generation: "generation", turns: [ServerTurn(speaker: 0, start: 0, text: "Hello there.")],
                       matches: [ServerVoiceMatch(speaker: 0, voice: "0123456789abcdef", name: "Maya")])
    }

    @Test func matchesNameBeforeStructuringAndNotXRejectsOnlyThatVoiceInThisNote() throws {
        var state = NoteVoiceState(), d = document()
        let names = state.receive(labels, session: "session", document: d, enabled: true)
        #expect(names == [1: "Maya"])
        for (person, name) in names { d.renameSpeaker(person, to: name) }
        #expect(try #require(d.nextStructureRequest()).transcript.contains("Maya:"))
        #expect(state.sources[1] == .note(session: "session", generation: "generation", speaker: 0))
        state.reject(1); d.renameSpeaker(1, to: nil)
        #expect(state.recognised.isEmpty && state.linked.isEmpty)
        #expect(state.receive(labels, session: "session", document: d, enabled: true).isEmpty)
        var other = labels
        other.matches = [ServerVoiceMatch(speaker: 0, voice: "fedcba9876543210", name: "Theo")]
        #expect(state.receive(other, session: "session", document: d, enabled: true) == [1: "Theo"])
    }

    @Test func disabledAndManualNamesAreNeverOverwrittenAndRememberIsOptional() {
        var state = NoteVoiceState(), d = document()
        #expect(state.receive(labels, session: "session", document: d, enabled: false).isEmpty)
        state.name(1, name: "Theo", remember: false)
        #expect(state.pending.isEmpty)
        d.renameSpeaker(1, to: "Theo")
        #expect(state.receive(labels, session: "session", document: d, enabled: true).isEmpty)
        state.name(1, name: "Theo", remember: true)
        #expect(state.pending == [1: "Theo"])
        state.name(1, name: nil, remember: true)
        #expect(state.pending.isEmpty)
    }

    @Test func aNewGenerationNamesNewPeopleWithoutReusingOldSources() {
        var state = NoteVoiceState(), d = document()
        _ = state.receive(labels, session: "session", document: d, enabled: true)
        var next = labels; next.generation = "restart"
        d.attachServerTurns(next.turns, generation: "restart", toSegment: 0)
        #expect(state.receive(next, session: "session", document: d, enabled: true) == [2: "Maya"])
        #expect(state.sources[2] == .note(session: "session", generation: "restart", speaker: 0))
    }

    @Test func voiceprintFieldsNeverReachTheNoteExportStructuringOrPreferences() throws {
        let marker = "0.915746238"
        let json = #"{"enabled":true,"model":"synthetic","voices":[{"id":"0123456789abcdef","name":"Maya","seconds":25,"created":"2026-01-01T00:00:00Z","updated":"2026-01-01T00:00:00Z","compatible":true,"embedding":[0.915746238]}]}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(SavedVoices.self, from: Data(json.utf8))
        var d = document(); d.renameSpeaker(1, to: library.voices[0].name)
        let values = [String(decoding: try JSONEncoder().encode(d), as: UTF8.self), d.exportMarkdown(),
                      try #require(d.nextStructureRequest()).transcript,
                      String(decoding: try JSONEncoder().encode(NotesPreferences()), as: UTF8.self)]
        #expect(values.allSatisfy { !$0.contains(marker) && !$0.contains("embedding") })
        #expect(!values.last!.contains("Maya"))
    }
}
