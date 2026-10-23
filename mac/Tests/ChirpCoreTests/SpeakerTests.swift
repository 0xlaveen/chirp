import ChirpUI
import Foundation
import Testing
@testable import ChirpCore

private func w(_ text: String, _ start: Double, _ end: Double) -> WordTiming { WordTiming(text: text, start: start, end: end) }
private func span(_ slot: Int, _ start: Double, _ end: Double) -> SpeakerSpan { SpeakerSpan(slot: slot, start: start, end: end) }

@Suite struct SpeakerAttributionTests {
    private func turns(_ words: [WordTiming]?, text: String? = nil, offset: Double = 0, end: Double = 10,
                       spans: [SpeakerSpan], previous: Int? = nil) -> [SpeakerAttribution.Turn]? {
        let raw = (words ?? []).map(\.text).joined(separator: " ")
        return SpeakerAttribution.turns(words: words, raw: raw, text: text ?? raw, offset: offset, end: end, spans: spans,
                                        previousSlot: previous)
    }

    @Test func wordsTakeTheSpanTheyOverlapMost() throws {
        let t = try #require(turns([w("we", 0, 0.3), w("ship", 0.3, 0.6), w("friday", 0.6, 1.0), w("agreed", 1.4, 1.9)],
                                   spans: [span(2, 0, 1.1), span(0, 0.95, 2.0)]))
        #expect(t.map(\.slot) == [2, 0])
        #expect(t.map(\.text) == ["we ship friday", "agreed"])
        #expect(t.map(\.start) == [0, 1.4])
    }

    @Test func segmentOffsetPlacesWordsInDocumentTime() throws {
        let t = try #require(turns([w("hello", 0.1, 0.5)], offset: 30, spans: [span(1, 0, 5), span(3, 29.9, 31)]))
        #expect(t == [SpeakerAttribution.Turn(slot: 3, start: 30.1, text: "hello")])
    }

    @Test func nearestSpanWithinOneSecondElseNeighbours() throws {
        // "so" sits 0.5 s after slot 1's span; "um" is 3 s from anything and inherits the word before it.
        let words = [w("right", 0, 0.4), w("so", 0.9, 1.0), w("um", 5, 5.2), w("next", 9, 9.5)]
        let t = try #require(turns(words, spans: [span(1, 0, 0.4), span(2, 8.8, 9.6)]))
        #expect(t.map(\.slot) == [1, 2])
        #expect(t.map(\.text) == ["right so um", "next"])
    }

    @Test func leadingWordsTheDiarizerMissedTakeTheNextSpeaker() throws {
        let t = try #require(turns([w("oh", 0, 0.2), w("yes", 5, 5.3), w("indeed", 5.3, 5.8)], spans: [span(3, 5, 6)]))
        #expect(t.map(\.slot) == [3] && t[0].text == "oh yes indeed")
    }

    @Test func noSpansAtAllFallBackToThePreviousSpeakerOrNothing() {
        #expect(turns([w("hello", 0, 0.5)], spans: [], previous: 2)?.map(\.slot) == [2])
        #expect(turns([w("hello", 0, 0.5)], spans: []) == nil)
    }

    @Test func aShortUndetectedRunBetweenOnePersonIsAbsorbed() throws {
        // "yeah" got slot 1 only as the nearest span; the diarizer never heard slot 1 for 0.3 s there.
        let words = [w("we", 0, 0.3), w("should", 0.3, 0.6), w("yeah", 2.05, 2.25), w("ship", 2.3, 2.6), w("it", 2.6, 2.8)]
        let t = try #require(turns(words, spans: [span(0, 0, 0.7), span(1, 1.0, 1.2), span(0, 2.3, 3.0)]))
        #expect(t.map(\.slot) == [0] && t[0].text == "we should yeah ship it")
    }

    @Test func aDetectedBackchannelIsKept() throws {
        let words = [w("we", 0, 0.3), w("should", 0.3, 0.6), w("yeah", 0.8, 1.0), w("ship", 1.3, 1.6), w("it", 1.6, 1.8)]
        let t = try #require(turns(words, spans: [span(0, 0, 0.7), span(1, 0.75, 1.15), span(0, 1.25, 2.0)]))
        #expect(t.map(\.slot) == [0, 1, 0])
        #expect(t.map(\.text) == ["we should", "yeah", "ship it"])
    }

    @Test func noTimingsGiveOneApproximateTurnForTheDominantSpeaker() throws {
        let t = try #require(SpeakerAttribution.turns(words: nil, raw: "a b c", text: "A b c.", offset: 10, end: 20,
                                                      spans: [span(0, 9, 12), span(2, 12, 19)]))
        #expect(t == [SpeakerAttribution.Turn(slot: 2, start: 10, text: "A b c.", raw: "a b c", approximate: true)])
        #expect(SpeakerAttribution.turns(words: [], raw: "x", text: "x", offset: 0, end: 1, spans: []) == nil)
    }

    // MARK: corrected text

    private let twoSpeakers = [w("so", 0, 0.2), w("we", 0.2, 0.4), w("ship", 0.4, 0.7), w("friday", 0.7, 1.0),
                               w("sounds", 2, 2.3), w("good", 2.3, 2.6)]
    private let twoSpans = [span(0, 0, 1.1), span(1, 1.9, 2.7)]

    @Test func identityAndPunctuationOnlyChangesKeepTheBoundary() throws {
        #expect(try #require(turns(twoSpeakers, spans: twoSpans)).map(\.text) == ["so we ship friday", "sounds good"])
        let t = try #require(turns(twoSpeakers, text: "So, we ship Friday. Sounds good!", spans: twoSpans))
        #expect(t.map(\.text) == ["So, we ship Friday.", "Sounds good!"])
        #expect(t.map(\.raw) == ["so we ship friday", "sounds good"])
        #expect(t.map(\.start) == [0, 2])
    }

    @Test func insertedWordsFollowTheWordBeforeAndDeletedOnesVanish() throws {
        let t = try #require(turns(twoSpeakers, text: "We ship on Friday. That sounds good.", spans: twoSpans))
        // "so" deleted; "on" inserted mid-turn; "That" inserted at the start of the second turn joins the first.
        #expect(t.map(\.text) == ["We ship on Friday. That", "sounds good."])
        #expect(t.map(\.slot) == [0, 1])
    }

    @Test func aDroppedTurnFoldsItsRawTextIntoTheTurnBefore() throws {
        let words = twoSpeakers + [w("ok", 3, 3.2), w("then", 3.2, 3.5)]
        let t = try #require(turns(words, text: "So we ship Friday. OK then.", spans: twoSpans + [span(0, 2.9, 3.6)]))
        // The clean-up dropped "sounds good": slot 1's raw words stay in the transcript's raw view, never lost.
        #expect(t.map(\.slot) == [0])
        #expect(t[0].text == "So we ship Friday. OK then.")
        #expect(t[0].raw == "so we ship friday sounds good ok then")
    }

    @Test func aHeavyRewriteKeepsTheRawTurns() throws {
        let t = try #require(turns(twoSpeakers, text: "The release is planned for the end of the week, which everyone accepted.",
                                   spans: twoSpans))
        #expect(t.map(\.text) == ["so we ship friday", "sounds good"])
        #expect(t.allSatisfy { $0.keptOriginal })
    }

    @Test func oneSpeakerKeepsTheWholeCorrectedText() throws {
        let t = try #require(turns(Array(twoSpeakers.prefix(4)), text: "Entirely different words here.", spans: twoSpans))
        #expect(t == [SpeakerAttribution.Turn(slot: 0, start: 0, text: "Entirely different words here.", raw: "so we ship friday")])
    }

    @Test func wordDiffAlignment() {
        #expect(WordDiff.alignment(raw: ["a", "b"], cleaned: ["A,", "b."]) == [0, 1])
        #expect(WordDiff.alignment(raw: ["a", "b", "c"], cleaned: ["a", "x", "c"]) == [0, nil, 2])
        #expect(WordDiff.alignment(raw: ["um", "a"], cleaned: ["a"]) == [1])
        // The HUD diff is unchanged by the refactor.
        #expect(WordDiff.segments(raw: "um hello world", cleaned: "Hello, world.")
                == [.init(.removed, "um"), .init(.changed, "Hello,"), .init(.changed, "world.")])
    }

    @Test func labellingSpansIncludeTheSettledPartOfOpenSpans() {
        let t = SpeakerTimeline(spans: [span(0, 0, 2)], finalizedThrough: 5, tentative: [span(1, 3, 7), span(2, 6, 7)])
        #expect(t.labellingSpans() == [span(0, 0, 2), span(1, 3, 5)])
        #expect(t.labellingSpans(includeTentative: true) == [span(0, 0, 2), span(1, 3, 7), span(2, 6, 7)])
    }
}

@Suite struct SpeakerRosterTests {
    @Test func peopleAreNumberedByFirstAppearance() {
        var r = SpeakerRoster()
        #expect(r.person(forSlot: 3) == 1)
        #expect(r.person(forSlot: 0) == 2)
        #expect(r.person(forSlot: 3) == 1)
        #expect(r.displayName(2) == "Person 2")
        #expect(r.slot(for: 1) == 3)
        #expect(r.existingPerson(forSlot: 2) == nil)
        #expect(r.colorIndex(1) == 0 && r.colorIndex(2) == 1)
    }

    @Test func renameIsSessionOnlyAndBlankGoesBack() {
        var r = SpeakerRoster()
        _ = r.person(forSlot: 0)
        r.rename(1, to: "  Maya ")
        #expect(r.displayName(1) == "Maya")
        r.rename(1, to: " ")
        #expect(r.displayName(1) == "Person 1")
    }

    @Test func chainedMergesResolveAndFutureAudioFollows() {
        var r = SpeakerRoster()
        for slot in [0, 1, 2] { _ = r.person(forSlot: slot) }
        r.rename(1, to: "Maya")
        r.merge(3, into: 2)
        r.merge(2, into: 1)
        #expect(r.resolve(3) == 1 && r.displayName(3) == "Maya")
        #expect(r.person(forSlot: 2) == 1)
        #expect(r.activeCount == 1)
        r.merge(1, into: 3)   // a cycle is refused: 3 already resolves to 1
        #expect(r.resolve(1) == 1)
        #expect(r.colorIndex(3) == r.colorIndex(1))
    }
}

@Suite struct SpeakerDocumentTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func labelled() -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        d.append(NotesSegment(id: 0, offset: 0, raw: "we will not hire a contractor ok", text: "We will not hire a contractor. OK.",
                              corrected: true))
        d.attachSpeakers([.init(slot: 2, start: 0, text: "We will not hire a contractor.", raw: "we will not hire a contractor"),
                          .init(slot: 0, start: 4.2, text: "OK.", raw: "ok")], toSegment: 0)
        d.append(NotesSegment(id: 1, offset: 72, raw: "unlabelled words"))
        d.append(NotesSegment(id: 2, offset: 80, raw: "maya sends the spec", text: "Maya sends the spec."))
        d.attachSpeakers([.init(slot: 0, start: 80.5, text: "Maya sends the spec.", raw: "maya sends the spec",
                                approximate: true)], toSegment: 2, tentative: true)
        return d
    }

    @Test func windowTranscriptHasOneLabelledLinePerTurn() throws {
        var d = labelled()
        #expect(try #require(d.nextStructureRequest()).transcript
                == "Person 1: We will not hire a contractor.\nPerson 2: OK.\nunlabelled words\nPerson 2: Maya sends the spec.")
        #expect(d.speakerCount == 2 && d.lastSpeakerSlot == 0)
        #expect(d.segments[2].labelsTentative && d.segments[2].turns?[0].approximate == true)
        // Display names everywhere: a later pass after a rename sends the name.
        d.renameSpeaker(2, to: "Maya")
        #expect(try #require(d.nextStructureRequest()).transcript.hasSuffix("Maya: OK.\nunlabelled words\nMaya: Maya sends the spec."))
    }

    @Test func exportLinesPerTurnWithDisplayNames() {
        let d = labelled()
        #expect(d.transcriptLines() == ["**[00:00:00] Person 1:** We will not hire a contractor.", "**[00:00:04] Person 2:** OK.",
                                        "**[00:01:12]** unlabelled words", "**[00:01:20] Person 2:** Maya sends the spec."])
        #expect(d.transcriptLines(raw: true)[0] == "**[00:00:00] Person 1:** we will not hire a contractor")
        #expect(d.exportMarkdown(timeZone: utc).contains("**[00:00:04] Person 2:** OK."))
    }

    @Test func withoutTurnsEverythingIsAsBefore() throws {
        var a = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        a.append(NotesSegment(id: 0, offset: 12, raw: "um hello", text: "Hello.", corrected: true))
        a.append(NotesSegment(id: 1, offset: 40, raw: "budget"))
        #expect(a.transcriptLines() == ["**[00:00:12]** Hello.", "**[00:00:40]** budget"])
        #expect(try #require(a.nextStructureRequest()).transcript == "Hello.\nbudget")
        #expect(a.segments.allSatisfy { $0.turns == nil && !$0.labelsTentative } && a.speakerCount == 0)
    }

    @Test func gapsAndUnknownSegmentsAreNeverLabelled() {
        var d = NotesDocument()
        d.append(.gap(id: 0, offset: 0, reason: "busy"))
        d.attachSpeakers([.init(slot: 0, start: 0, text: "x")], toSegment: 0)
        d.attachSpeakers([.init(slot: 0, start: 0, text: "x")], toSegment: 5)
        #expect(d.segments[0].turns == nil && d.roster.people.isEmpty)
    }

    @Test func keptOriginalTurnsAreMarkedInTheExport() {
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 0, raw: "a b", text: "Totally new.", corrected: true))
        d.attachSpeakers([.init(slot: 0, start: 0, text: "a", keptOriginal: true), .init(slot: 1, start: 1, text: "b", keptOriginal: true)],
                         toSegment: 0)
        #expect(d.transcriptLines() == ["**[00:00:00] Person 1:** a _(kept original)_", "**[00:00:01] Person 2:** b _(kept original)_"])
    }

    @Test func notesStartOptionsAlwaysAskForWordTimings() {
        let name = "chirp-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        #expect(!prefs.notesSpeakerLabels)
        let health = Health(correction: "available", notesCorrection: true)
        // Always on: the overlap trim at a hard cut needs them as much as the speaker labels do.
        #expect(ClientMessage.start(prefs.notesStartOptions(health: health)).contains("\"word_timings\":true"))
        prefs.notesSpeakerLabels = true
        #expect(Preferences(defaults: defaults).notesSpeakerLabels)
    }
}

@MainActor
@Suite(.serialized) struct SpeakerRecorderTests {
    private let frame = Data(count: 1600)
    private let speech = Level(peak: 0.5, rms: 0.2)

    private func final(_ text: String, raw: String, words: [(String, Double, Double)]?) -> String {
        let list = words.map { ws in
            ",\"words\":[" + ws.map { "{\"text\":\"\($0.0)\",\"start\":\($0.1),\"end\":\($0.2)}" }.joined(separator: ",") + "]"
        } ?? ""
        return "{\"type\":\"final\",\"text\":\"\(text)\",\"raw\":\"\(raw)\",\"corrected\":true\(list)}"
    }

    private var twoVoices: String {
        final("We ship Friday. Agreed.", raw: "we ship friday agreed",
              words: [("we", 0, 0.15), ("ship", 0.15, 0.3), ("friday", 0.3, 0.45), ("agreed", 0.6, 0.9)])
    }

    private func make(_ port: UInt16, stub: StructureStub, clock: ManualClock) -> NotesRecorder {
        let config = ServerConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        // Its own connection pool: URLSession.shared allows 6 connections per host, shared with the other suites'
        // mock servers running in parallel.
        let urlSession = URLSession(configuration: .ephemeral)
        return NotesRecorder(makeSession: { StreamSession(config: config, options: $0, urlSession: urlSession) },
                             structure: { try await stub.call($0) },
                             now: { clock.now }, sleep: { await clock.sleep($0) },
                             options: StartOptions(client: "mac", correction: true, wordTimings: true), structuring: true,
                             health: Health(correction: "available", notesStructure: true))
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        if !(await pollUntil(within: 60, condition)) { Issue.record("timed out waiting for \(what)") }
    }

    private func record(_ r: NotesRecorder, frames: Int) async {
        r.start()
        await eventually("ready") { r.state == .recording }
        for _ in 0..<frames { r.handleFrame(frame, level: speech) }
    }

    @Test func labelsLandAndThePassSendsThem() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        server.script(0, .init(final: twoVoices))
        let stub = StructureStub(), clock = ManualClock()
        let fake = FakeDiarizer(script: [span(3, 0, 0.5), span(1, 0.55, 1.0)], lag: 0)
        let r = make(port, stub: stub, clock: clock)
        var lags: [Bool] = []
        r.onLabels = { _, tentative in lags.append(tentative) }
        r.speakers = fake
        await record(r, frames: 20)
        await r.stop()
        let turns = try #require(r.document.segments.first?.turns)
        #expect(turns.map(\.person) == [1, 2])
        #expect(turns.map(\.text) == ["We ship Friday.", "Agreed."])
        #expect(stub.requests.last?.transcript == "Person 1: We ship Friday.\nPerson 2: Agreed.")
        #expect(fake.flushes == 1 && fake.framesFed == 20 && lags == [false])
        #expect(r.document.speakerCount == 2 && r.labellingCount == 0)
    }

    @Test func lateLabelsHoldThePassThenLandTentative() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        server.script(0, .init(final: twoVoices))
        let stub = StructureStub(), clock = ManualClock()
        // Ten seconds behind live: it never settles segment 0 while recording.
        let fake = FakeDiarizer(script: [span(3, 0, 0.5), span(1, 0.55, 1.0)], lag: 10)
        let r = make(port, stub: stub, clock: clock)
        r.speakers = fake
        await record(r, frames: 20)
        await r.cut()
        await eventually("committed, labels pending") { r.document.segments.count == 1 && r.labellingCount == 1 }
        // The text is in at once; the pass waits for the labels.
        #expect(r.document.segments[0].text == "We ship Friday. Agreed." && r.document.segments[0].turns == nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(stub.requests.isEmpty)
        clock.advance(NotesRecorder.labelTimeout + 0.1)
        await eventually("tentative labels") { r.document.segments[0].turns != nil }
        #expect(r.document.segments[0].labelsTentative)
        await eventually("the pass") { !stub.requests.isEmpty }
        #expect(stub.requests[0].transcript == "Person 1: We ship Friday.\nPerson 2: Agreed.")
        await r.stop()
        // Stop's flush settled the diarizer: the tentative labels were attached again from the settled timeline.
        #expect(!r.document.segments[0].labelsTentative)
    }

    /// Privacy: a full labelled session (two recordings, labels, a pass, New) writes nothing under Application
    /// Support or Chirp's caches. Labels, names and the timeline live in memory only.
    @Test func aLabelledSessionWritesNoFiles() async throws {
        let before = SpeakerPrivacyTests.footprint()
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        server.script(0, .init(final: twoVoices))
        server.script(1, .init(final: twoVoices))
        let stub = StructureStub(), clock = ManualClock()
        let fake = FakeDiarizer(script: [span(3, 0, 0.5), span(1, 0.55, 1.0), span(3, 1.0, 1.5), span(1, 1.55, 2.0)], lag: 0)
        let r = make(port, stub: stub, clock: clock)
        r.speakers = fake
        await record(r, frames: 20)
        await r.stop()
        await record(r, frames: 20)
        await r.stop()
        #expect(r.document.speakerCount == 2 && !stub.requests.isEmpty)
        _ = r.document.exportMarkdown()          // what Copy would put on the pasteboard; Save… is the user's choice
        r.reset()
        let after = SpeakerPrivacyTests.footprint()
        // Other apps write under Application Support meanwhile: only Chirp's and FluidAudio's own paths count.
        let changed = after.filter { before[$0.key] != $0.value }.map(\.key)
            .filter { $0.localizedCaseInsensitiveContains("chirp") || $0.contains("FluidAudio") }
        #expect(changed.isEmpty, "\(changed)")
    }

    @Test func stopWaitsForTheFlushSoTheNextRecordStartsAfterIt() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        server.script(0, .init(final: twoVoices))
        let stub = StructureStub(), clock = ManualClock()
        let fake = FakeDiarizer(script: [span(3, 0, 0.5), span(1, 0.55, 1.0)], lag: 0)
        fake.holdFlush = true
        let r = make(port, stub: stub, clock: clock)
        r.speakers = fake
        await record(r, frames: 20)
        let stopped = Task { await r.stop() }
        await eventually("flush waiting") { fake.flushWaiting }
        try? await Task.sleep(for: .milliseconds(100))
        // Still finishing: Record cannot start while the Stop silence is not in the model yet.
        #expect(r.state == .stopping)
        r.start()
        #expect(r.state == .stopping)
        fake.releaseFlush()
        await stopped.value
        #expect(r.state == .stopped && fake.flushes == 1)
    }

    @Test func recordAfterStopKeepsPersonNumbers() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        server.script(0, .init(final: final("Hello there.", raw: "hello there", words: [("hello", 0, 0.4), ("there", 0.4, 0.9)])))
        server.script(1, .init(final: final("Hi. Back again.", raw: "hi back again",
                                            words: [("hi", 0, 0.4), ("back", 0.55, 0.75), ("again", 0.75, 1.0)])))
        let stub = StructureStub(), clock = ManualClock()
        let fake = FakeDiarizer(script: [span(2, 0, 1)], lag: 0)
        let r = make(port, stub: stub, clock: clock)
        r.speakers = fake
        await record(r, frames: 20)
        await r.stop()
        fake.setScript([span(2, 0, 1), span(0, 1.0, 1.45), span(2, 1.5, 2.0)])
        await record(r, frames: 20)
        await r.stop()
        #expect(r.document.segments.map { $0.turns?.map(\.person) } == [[1], [2, 1]])
        #expect(r.document.segments[1].turns?[1].start == 1.55)
        #expect(fake.resets == 0 && fake.flushes == 2)
        r.reset()
        #expect(fake.resets == 1 && r.document.roster.people.isEmpty)
    }

    @Test func cancelDropsPendingLabels() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        server.script(0, .init(final: twoVoices))
        let stub = StructureStub(), clock = ManualClock()
        let r = make(port, stub: stub, clock: clock)
        r.speakers = FakeDiarizer(script: [span(0, 0, 1)], lag: 10)
        await record(r, frames: 20)
        await r.cut()
        await eventually("labels pending") { r.labellingCount == 1 }
        r.cancel()
        #expect(r.labellingCount == 0 && r.document.segments[0].turns == nil)
        clock.advance(10)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.document.segments[0].turns == nil)
    }

    @Test func withoutADiarizerNothingIsLabelled() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        server.script(0, .init(final: twoVoices))
        let stub = StructureStub(), clock = ManualClock()
        let r = make(port, stub: stub, clock: clock)
        await record(r, frames: 20)
        await r.stop()
        #expect(r.document.segments[0].turns == nil && r.labellingCount == 0)
        #expect(stub.requests.last?.transcript == "We ship Friday. Agreed.")
    }
}

/// Privacy (issue #18): the label path keeps everything in memory and logs numbers only.
@Suite struct SpeakerPrivacyTests {
    @Test func theLogLineCarriesCountsAndTimingsOnly() {
        let line = SpeakerLog.labels(speakers: 3, lag: 0.4204, tentative: false)
        #expect(line == "notes labels speakers=3 lag_ms=420 tentative=false")
        #expect(line.range(of: #"^notes labels speakers=\d+ lag_ms=\d+ tentative=(true|false)$"#, options: .regularExpression) != nil)
    }

    /// Apache-2.0 §4(a) and CC BY 4.0: the app bundle ships FluidAudio's licence and the model's attribution.
    @Test func theNoticesShipInTheAppBundle() throws {
        let mac = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let notices = try String(contentsOf: mac.appendingPathComponent("Assets/ThirdParty/NOTICES.md"), encoding: .utf8)
        #expect(notices.contains("CC BY 4.0") && notices.contains("ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1")
                && notices.contains("nvidia/diar_streaming_sortformer_4spk-v2.1"))
        let licence = try String(contentsOf: mac.appendingPathComponent("Assets/ThirdParty/FluidAudio/LICENSE.txt"), encoding: .utf8)
        #expect(licence.contains("Apache License") && licence.contains("Version 2.0"))
        let bundle = try String(contentsOf: mac.appendingPathComponent("scripts/bundle.sh"), encoding: .utf8)
        #expect(bundle.contains("cp -R Assets/ThirdParty \"$APP/Contents/Resources/ThirdParty\""))
    }

    /// What a labelled session could leave behind: everything under Application Support and Chirp's caches (the
    /// bench's own audio aside), with modification dates.
    static func footprint() -> [String: Date] {
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        var out: [String: Date] = [:]
        for root in [library.appendingPathComponent("Application Support"), library.appendingPathComponent("Caches/Chirp")] {
            guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                           options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walk {
                let path = url.path
                if path.contains("/speaker-bench") || path.contains("/FluidAudio/Models") { walk.skipDescendants(); continue }
                if walk.level > 3 { walk.skipDescendants() }
                out[path] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
        }
        return out
    }

}

@MainActor
@Suite struct SpeakerTranscriptRowTests {
    private func model() -> NotesModel {
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 0, raw: "a b c"))
        d.attachSpeakers([.init(slot: 1, start: 0, text: "a"), .init(slot: 2, start: 5, text: "b"),
                          .init(slot: 2, start: 30, text: "c")], toSegment: 0)
        d.append(NotesSegment(id: 1, offset: 40, raw: "d e"))
        d.attachSpeakers([.init(slot: 2, start: 40, text: "d"), .init(slot: 2, start: 70, text: "e", approximate: true)],
                         toSegment: 1)
        d.append(NotesSegment(id: 2, offset: 80, raw: "plain"))
        d.append(NotesSegment(id: 3, offset: 90, raw: "f"))
        d.attachSpeakers([.init(slot: 2, start: 90, text: "f")], toSegment: 3)
        let m = NotesModel()
        m.document = d
        return m
    }

    @Test func chipsCollapseForOnePersonAcrossSegmentsAndRepeatAfterAMinute() {
        let rows = model().transcriptRows
        #expect(rows.map(\.id) == ["0.0", "0.1", "0.2", "1.0", "1.1", "2", "3.0"])
        #expect(rows.map { $0.chip?.name } == ["Person 1", "Person 2", nil, nil, "Person 2", nil, "Person 2"])
        // The repeated chip at 70 s is the approximate turn's, dotted.
        #expect(rows[4].chip?.approximate == true)
        #expect(rows.map(\.offset) == [0, 5, 30, 40, 70, 80, 90])
    }

    @Test func footerStatusFollowsTheModelAndTheCount() {
        let m = model()
        #expect(m.speakerStatus == nil)          // labels off
        m.speakerLabels = true
        m.speakerModel = .ready
        #expect(m.speakerStatus == "2 speakers")
        m.speakerModel = .downloading(0.416)
        #expect(m.speakerStatus == "Downloading speaker model… 42%")
        m.speakerModel = .failed("the download failed")
        #expect(m.speakerStatus == "Speaker labels unavailable: the download failed")
        #expect(NotesStatus.speakerDownloadPrompt(size: "234 MB")
                == "Speaker labels need a 234 MB on-device model, downloaded once. Audio never leaves this Mac.")
    }
}

/// Speaker labels in #25's editable document: the Hearing strip, fallback blocks (what Organize re-structures).
@MainActor
@Suite struct SpeakerEditableNotesTests {
    private func labelled() -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        d.append(NotesSegment(id: 0, offset: 0, raw: "we ship friday ok", text: "We ship Friday. OK."))
        d.attachSpeakers([.init(slot: 1, start: 0, text: "We ship Friday."), .init(slot: 0, start: 3, text: "OK.")], toSegment: 0)
        d.append(NotesSegment(id: 1, offset: 20, raw: "and the beta", text: "And the beta."))
        d.attachSpeakers([.init(slot: 0, start: 20, text: "And the beta.")], toSegment: 1)
        d.append(NotesSegment(id: 2, offset: 40, raw: "unlabelled words"))
        return d
    }

    @Test func theHearingStripNamesWhoIsTalkingWhereTheSpeakerChanges() {
        let m = NotesModel()
        m.document = labelled()
        m.document.livePartial = "and then"
        #expect(m.hearingParts.map(\.name) == ["Person 1", "Person 2", nil, nil, nil])
        #expect(m.hearingText == "Person 1: We ship Friday. Person 2: OK. And the beta. unlabelled words and then")
        #expect(m.hearingParts[1].color == 1)
    }

    @Test func withoutLabelsTheHearingStripIsUnchanged() {
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 0, raw: "we ship friday"))
        d.append(NotesSegment(id: 1, offset: 20, raw: "and the beta"))
        d.livePartial = "and then"
        let m = NotesModel()
        m.document = d
        #expect(m.hearingText == [d.unstructuredTail, d.livePartial].joined(separator: " "))
        #expect(m.hearingParts.allSatisfy { $0.name == nil })
    }

    @Test func aFallbackBlockKeepsWhoSaidWhatForOrganize() {
        var d = labelled()
        d.freezeAll()
        #expect(d.text == NotesDocument.fallbackBlock("Person 1: We ship Friday.\n\nPerson 2: OK.\n\nPerson 2: And the beta.\n\nunlabelled words"))
        #expect(d.untouchedFallbacks.first?.body.hasPrefix("Person 1: We ship Friday.") == true)
        var plain = NotesDocument()
        plain.append(NotesSegment(id: 0, offset: 0, raw: "a"))
        plain.append(NotesSegment(id: 1, offset: 9, raw: "b"))
        plain.freezeAll()
        #expect(plain.text == NotesDocument.fallbackBlock("a\n\nb"))
    }
}
