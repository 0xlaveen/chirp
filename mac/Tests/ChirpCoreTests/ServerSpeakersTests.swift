import Foundation
import Testing
@testable import ChirpCore

/// Live Notes speaker labels from the server (#187, #201): the wire fields, the roster's server generations, the turns
/// cut down to an overlapped segment, and the recorder carrying them into the note. Android has the same suite.
@Suite struct ServerSpeakersWireTests {
    private func final(_ json: String) throws -> FinalResult {
        guard case .final(let f) = try ServerMessage.decode(Data(json.utf8)) else { throw CocoaError(.coderInvalidValue) }
        return f
    }

    @Test func aFinalCarriesItsTurns() throws {
        let f = try final(#"""
        {"type":"final","text":"We ship Friday. Okay.","raw":"we ship friday okay","corrected":true,"speakers":{"generation":"9f2c","turns":[
        {"speaker":0,"start":0.48,"end":3.1,"text":"We ship Friday.","raw":"we ship friday","approximate":false,"kept_original":false},
        {"speaker":1,"start":3.4,"end":5.02,"text":"Okay.","raw":"okay","approximate":true,"kept_original":true}]}}
        """#)
        #expect(f.speakers?.generation == "9f2c")
        #expect(f.speakers?.turns == [ServerTurn(speaker: 0, start: 0.48, text: "We ship Friday.", raw: "we ship friday"),
                                      ServerTurn(speaker: 1, start: 3.4, text: "Okay.", raw: "okay", approximate: true, keptOriginal: true)])
    }

    @Test func aFinalWithoutTheFieldIsAsBefore() throws {
        #expect(try final(#"{"type":"final","text":"Hi.","raw":"hi","corrected":true}"#).speakers == nil)
    }

    @Test func anErrorIsNoLabelsNeverAFailedSegment() throws {
        let f = try final(#"{"type":"final","text":"Hi.","raw":"hi","speakers":{"error":"unavailable"}}"#)
        #expect(f.text == "Hi." && f.speakers == ServerSpeakers(generation: nil, turns: [], error: "unavailable"))
        #expect(try final(#"{"type":"final","text":"Hi.","raw":"hi","speakers":{"error":"Not OK!"}}"#).speakers == nil)
    }

    @Test func malformedSpeakersAreDroppedAndTheTextStays() throws {
        for bad in [#"{"generation":"g","turns":[{"speaker":99,"start":0,"text":"x"}]}"#, #"{"generation":"","turns":[]}"#,
                    #"{"turns":[]}"#, #"{"generation":"g","turns":"no"}"#, "7", #"{"generation":"g","turns":[{"speaker":0}]}"#] {
            let f = try final(#"{"type":"final","text":"Hi.","raw":"hi","corrected":true,"speakers":\#(bad)}"#)
            #expect(f.speakers == nil && f.text == "Hi." && f.corrected)
        }
    }

    @Test func tooManyTurnsAreDropped() throws {
        let turn = #"{"speaker":0,"start":0,"text":"x"}"#
        let many = Array(repeating: turn, count: ServerSpeakers.maxTurns + 1).joined(separator: ",")
        #expect(try final(#"{"type":"final","text":"x","speakers":{"generation":"g","turns":[\#(many)]}}"#).speakers == nil)
    }

    @Test func startAsksOnlyWhenOnAndWithAValidSession() throws {
        func start(_ o: StartOptions) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(ClientMessage.start(o).utf8)) as? [String: Any])
        }
        #expect(try start(StartOptions(client: "ios"))["speakers"] == nil)
        let id = SpeakerSession.make()
        #expect(SpeakerSession.isValid(id) && id.count == 32 && SpeakerSession.make() != id)
        #expect((try start(StartOptions(client: "ios", speakersSession: id))["speakers"] as? [String: String]) == ["session": id])
        #expect(try start(StartOptions(client: "ios", speakersSession: "short"))["speakers"] == nil)
        #expect(try start(StartOptions(client: "ios", speakersSession: String(repeating: "a", count: 65)))["speakers"] == nil)
        #expect(try start(StartOptions(client: "ios", speakersSession: "bad session id with spaces!!!"))["speakers"] == nil)
        // Without the field the message is byte-identical to before.
        #expect(ClientMessage.start(StartOptions(client: "ios")) == ClientMessage.start(StartOptions(client: "ios", speakersSession: nil)))
    }

    @Test func healthAdvertisesTheFeatureAndTheModel() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let h = try decoder.decode(Health.self, from: Data(#"{"ok":true,"notes_speakers":true,"speakers_model":{"state":"not_downloaded","size_bytes":26530309}}"#.utf8))
        #expect(h.notesSpeakers == true && h.speakersModel == SpeakersModel(state: .notDownloaded, sizeBytes: 26_530_309))
        let old = try decoder.decode(Health.self, from: Data(#"{"ok":true}"#.utf8))
        #expect(old.notesSpeakers == nil && old.speakersModel == nil)
        let odd = try decoder.decode(Health.self, from: Data(#"{"ok":true,"speakers_model":{"state":"somewhere"}}"#.utf8))
        #expect(odd.speakersModel?.state == nil)
    }
}

@Suite struct ServerSpeakersDocumentTests {
    private func turn(_ speaker: Int, _ start: Double, _ text: String) -> ServerTurn { ServerTurn(speaker: speaker, start: start, text: text) }

    @Test func peopleAreNumberedInTranscriptOrderAndRunsMerge() {
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 10, raw: "a b c", text: "A b c."))
        d.attachServerTurns([turn(5, 0, "A"), turn(5, 1, "b"), turn(2, 2, "c.")], generation: "g1", toSegment: 0)
        #expect(d.segments[0].turns?.map(\.person) == [1, 2])
        #expect(d.segments[0].turns?.first?.text == "A b" && d.segments[0].turns?.first?.start == 10)
        #expect(d.segments[0].turns?.last?.start == 12)
        d.append(NotesSegment(id: 1, offset: 20, raw: "d", text: "D."))
        d.attachServerTurns([turn(2, 0, "D.")], generation: "g1", toSegment: 1)
        #expect(d.segments[1].turns?.map(\.person) == [2] && d.speakerCount == 2)
        #expect(d.labelledText(d.segments[1]) == "Person 2: D.")
    }

    @Test func aNewGenerationForgetsSlotsAndKeepsPeople() {
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 0, raw: "a", text: "A."))
        d.attachServerTurns([turn(0, 0, "A.")], generation: "g1", toSegment: 0)
        d.renameSpeaker(1, to: "Maya")
        d.append(NotesSegment(id: 1, offset: 5, raw: "b", text: "B."))
        // The server restarted: its slot 0 may be anyone. A new person, the first one keeps their name.
        d.attachServerTurns([turn(0, 0, "B.")], generation: "g2", toSegment: 1)
        #expect(d.segments[1].turns?.map(\.person) == [2])
        #expect(d.roster.displayName(1) == "Maya" && d.roster.displayName(2) == "Person 2")
    }

    @Test func renameMergeAndSeparateReachEveryTurn() {
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 0, raw: "a b", text: "A. B."))
        d.attachServerTurns([turn(0, 0, "A."), turn(1, 1, "B.")], generation: "g", toSegment: 0)
        d.renameSpeaker(2, to: "Maya")
        #expect(d.labelledText(d.segments[0]) == "Person 1: A.\nMaya: B.")
        d.mergeSpeaker(2, into: 1)
        #expect(d.labelledText(d.segments[0]) == "Person 1: A.\nPerson 1: B.")
        d.separateSpeaker(2)
        #expect(d.labelledText(d.segments[0]) == "Person 1: A.\nMaya: B.")
    }

    @Test func theSealedNoteKeepsTheLabelsAndTheGeneration() throws {
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 0, raw: "a b", text: "A. B."))
        d.attachServerTurns([turn(0, 0, "A."), turn(1, 1, "B.")], generation: "g", toSegment: 0)
        d.renameSpeaker(1, to: "Maya")
        var back = try JSONDecoder().decode(NotesDocument.self, from: JSONEncoder().encode(d))
        #expect(back.segments[0].turns == d.segments[0].turns && back.roster.displayName(1) == "Maya")
        // Same generation after a reload: the slot map is kept, so the same voice stays the same person.
        back.append(NotesSegment(id: 1, offset: 5, raw: "c", text: "C."))
        back.attachServerTurns([turn(1, 0, "C.")], generation: "g", toSegment: 1)
        #expect(back.segments[1].turns?.map(\.person) == [2])
    }

    @Test func aRosterSavedBeforeGenerationsStillDecodes() throws {
        let old = #"{"people":[{"id":1,"name":"Maya"}],"slots":{"0":1}}"#
        let roster = try JSONDecoder().decode(SpeakerRoster.self, from: Data(old.utf8))
        #expect(roster.displayName(1) == "Maya")
    }
}

@Suite struct ServerTurnsRestrictTests {
    private func turn(_ speaker: Int, _ text: String, raw: String? = nil, kept: Bool = false) -> ServerTurn {
        ServerTurn(speaker: speaker, start: 0, text: text, raw: raw, keptOriginal: kept)
    }
    private let turns: [ServerTurn] = [
        ServerTurn(speaker: 0, start: 0, text: "We ship Friday.", raw: "we ship friday"),
        ServerTurn(speaker: 1, start: 2, text: "Okay sounds good.", raw: "okay sounds good")]

    @Test func untrimmedTurnsAreUnchanged() {
        let sent = (text: "We ship Friday. Okay sounds good.", raw: "we ship friday okay sounds good")
        #expect(ServerTurns.restrict(turns, text: sent.text, raw: sent.raw, original: sent) == turns)
    }

    @Test func aTrimmedStartAndEndCutTheTurnsToTheKeptWords() throws {
        let sent = (text: "We ship Friday. Okay sounds good.", raw: "we ship friday okay sounds good")
        let cut = try #require(ServerTurns.restrict(turns, text: "ship Friday. Okay sounds", raw: "ship friday okay sounds", original: sent))
        #expect(cut.map(\.text) == ["ship Friday.", "Okay sounds"] && cut.map(\.raw) == ["ship friday", "okay sounds"])
        #expect(cut.map(\.speaker) == [0, 1])
    }

    @Test func aTurnTrimmedAwayEntirelyDisappears() throws {
        let sent = (text: "We ship Friday. Okay sounds good.", raw: "we ship friday okay sounds good")
        let cut = try #require(ServerTurns.restrict(turns, text: "Okay sounds good.", raw: "okay sounds good", original: sent))
        #expect(cut.map(\.speaker) == [1] && cut[0].text == "Okay sounds good.")
    }

    @Test func aDedupedFirstWordLeavesTheRest() throws {
        let sent = (text: "We ship Friday. Okay sounds good.", raw: "we ship friday okay sounds good")
        let cut = try #require(ServerTurns.restrict(turns, text: "ship Friday. Okay sounds good.", raw: "ship friday okay sounds good", original: sent))
        #expect(cut.map(\.text) == ["ship Friday.", "Okay sounds good."])
    }

    @Test func keptOriginalTurnsFollowTheRawText() throws {
        let kept = [turn(0, "we ship friday", raw: "we ship friday", kept: true), turn(1, "okay sounds good", raw: "okay sounds good", kept: true)]
        let sent = (text: "We ship Friday, OK, sounds good.", raw: "we ship friday okay sounds good")
        let cut = try #require(ServerTurns.restrict(kept, text: "Friday, OK.", raw: "friday okay", original: sent))
        #expect(cut.map(\.text) == ["friday", "okay"])
    }

    @Test func textTheTurnsDoNotContainIsNoLabels() {
        let sent = (text: "We ship Friday. Okay sounds good.", raw: "we ship friday okay sounds good")
        #expect(ServerTurns.restrict(turns, text: "Something else entirely", raw: "x", original: sent) == nil)
        #expect(ServerTurns.restrict(turns, text: "", raw: "", original: sent) == nil)
    }
}

@MainActor
@Suite(.serialized) struct ServerSpeakersRecorderTests {
    private let frame = Data(count: 1600)
    private let speech = Level(peak: 0.5, rms: 0.2)

    private func make(port: UInt16, labels: Bool) -> NotesRecorder {
        let config = ServerConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let r = NotesRecorder(makeSession: { StreamSession(config: config, options: $0) },
                              structure: { _ in NotesStructureResponse(markdown: nil, structured: false, error: "off") },
                              now: { 0 }, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                              options: StartOptions(client: "ios", correction: true), structuring: false)
        r.labelSpeakers = labels
        return r
    }

    private func final(_ n: Int, _ speaker: Int, generation: String = "g1") -> String {
        #"{"type":"final","text":"Segment \#(n).","raw":"segment \#(n)","corrected":true,"speakers":{"generation":"\#(generation)","turns":[{"speaker":\#(speaker),"start":0,"text":"Segment \#(n).","raw":"segment \#(n)"}]}}"#
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        if !(await pollUntil(within: 60, condition)) { Issue.record("timed out waiting for \(what)") }
    }

    private func record(_ r: NotesRecorder, segments: Int) async {
        r.start()
        await eventually("ready") { r.state == .recording }
        for _ in 0..<segments {
            for _ in 0..<2 { r.handleFrame(frame, level: speech) }
            await r.cut()
        }
        await r.stop()
    }

    @Test func labelsAskedForAndCarriedIntoTheNote() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        server.script(0, .init(final: final(0, 4)))
        server.script(1, .init(final: final(1, 9)))
        server.script(2, .init(final: final(2, 4)))
        let r = make(port: port, labels: true)
        await record(r, segments: 2)
        let starts = server.received.filter { $0.contains(#""type":"start""#) }
        #expect(starts.count >= 2 && starts.allSatisfy { $0.contains(#""speakers":{"session":""#) })
        let sessions = Set(starts.compactMap { $0.components(separatedBy: #""session":""#).dropFirst().first?.prefix(32) })
        #expect(sessions.count == 1)
        #expect(r.document.segments.compactMap { $0.turns?.first?.person } == [1, 2, 1])
        #expect(r.document.labelledText(r.document.segments[1]) == "Person 2: Segment 1.")
        #expect(r.speakerError == nil)
    }

    @Test func labelsOffNeverAsksAndIgnoresWhatComes() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        server.script(0, .init(final: final(0, 4)))
        let r = make(port: port, labels: false)
        await record(r, segments: 1)
        #expect(server.received.allSatisfy { !$0.contains("speakers") })
        #expect(r.document.segments.allSatisfy { $0.turns == nil })
    }

    @Test func aMissingModelLeavesTheTextAndSaysWhy() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        let unavailable = #"{"type":"final","text":"Segment 0.","raw":"segment 0","corrected":true,"speakers":{"error":"unavailable"}}"#
        server.script(0, .init(final: unavailable))
        let r = make(port: port, labels: true)
        await record(r, segments: 0)
        #expect(r.document.segments.first?.text == "Segment 0." && r.document.segments.first?.turns == nil)
        #expect(r.speakerError == "unavailable")
    }

    @Test func eachNoteHasItsOwnSessionAndRestoreStartsANewOne() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        server.numberedFinals = true
        let a = make(port: port, labels: true), b = make(port: port, labels: true)
        #expect(a.startOptions.speakersSession != nil && a.startOptions.speakersSession != b.startOptions.speakersSession)
        let before = a.startOptions.speakersSession
        a.restore(NotesDocument(), elapsed: 0)
        #expect(a.startOptions.speakersSession != before)
        a.labelSpeakers = false
        #expect(a.startOptions.speakersSession == nil)
    }
}
