import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Long dictation (#64): seamless cuts, cross-segment context, the paragraph transcript, whole-document Organize,
/// long-run UX and the multi-hour budgets.
private let speech = Level(peak: 0.5, rms: 0.2)
private let quiet = Level(peak: 0.01, rms: 0.005)

@Suite struct NotesLongSegmenterTests {
    private func run(_ s: inout NotesSegmenter, _ level: Level, for seconds: Double) -> Double? {
        for _ in 0..<Int((seconds / 0.05).rounded()) where s.feed(level, duration: 0.05) { return s.elapsed }
        return nil
    }

    @Test func aDipFromThirtyFiveSecondsIsACut() {
        var s = NotesSegmenter()
        #expect(run(&s, speech, for: 33) == nil)
        #expect(run(&s, quiet, for: 0.15) == nil)          // before 35 s a 0.15 s dip is not enough
        #expect(run(&s, speech, for: 2) == nil)
        let cut = run(&s, quiet, for: 0.15)
        #expect(cut != nil && abs(cut! - 35.3) < 0.01 && !s.hardCut)
    }

    @Test func onlyTheFortyFiveSecondCutIsHard() {
        var s = NotesSegmenter()
        #expect(run(&s, speech, for: 60).map { abs($0 - NotesSegmenter.maxSegment) < 0.001 } == true)
        #expect(s.hardCut)
        s.reset()
        #expect(!s.hardCut)
        _ = run(&s, speech, for: 15)
        #expect(run(&s, quiet, for: 1) != nil && !s.hardCut)
    }
}

/// Records every frame a session sends, in order.
final class RecordingTransport: StreamTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [Data] = []
    private var _texts: [String] = []
    var frames: [Data] { lock.withLock { _frames } }
    var texts: [String] { lock.withLock { _texts } }
    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock {
            switch message {
            case .data(let d): _frames.append(d)
            case .string(let s): _texts.append(s)
            @unknown default: break
            }
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await Task.sleep(for: .seconds(60)); throw CancellationError() }
    func cancel(with code: URLSessionWebSocketTask.CloseCode) {}
}

@Suite struct NotesOverlapRouterTests {
    private func session(_ t: RecordingTransport) async -> StreamSession {
        var limits = StreamLimits()
        limits.maxQueuedBytes = .max
        let s = StreamSession(transport: t, options: StartOptions(), limits: limits)
        await s.open()
        return s
    }

    /// Frame `i` carries `i` in its first two bytes.
    private func frame(_ i: Int) -> Data {
        var d = Data(count: 1600)
        d[0] = UInt8(i & 0xff)
        d[1] = UInt8(i >> 8)
        return d
    }

    private func index(_ d: Data) -> Int { Int(d[0]) | Int(d[1]) << 8 }

    @Test func aHardCutSendsTheLastSecondToBothSocketsAndEveryOtherFrameToOne() async {
        let a = RecordingTransport(), b = RecordingTransport()
        let first = await session(a), second = await session(b)
        let router = NotesFrameRouter()
        _ = router.swap(to: first)
        var asked: Int?
        for i in 0..<903 where router.route(frame(i), level: speech) { asked = asked ?? i }
        #expect(asked == 899)                                    // 45 s of speech
        let swap = router.swap(to: second)
        for i in 903..<910 { _ = router.route(frame(i), level: speech) }
        await first.stop()
        await second.stop()
        #expect(abs(swap.overlap - NotesSegmenter.overlap) < 0.001 && swap.offset == 45.15)
        let one = a.frames.map(index), two = b.frames.map(index)
        #expect(one == Array(0..<903))
        #expect(two == Array(883..<910))                         // the old socket's last 20 frames (1 s), then new audio
        #expect(Set(one).intersection(two) == Set(883..<903))
    }

    @Test func aPauseCutHasNoOverlapAndMeasuresThePause() async {
        let a = RecordingTransport(), b = RecordingTransport()
        let first = await session(a), second = await session(b)
        let router = NotesFrameRouter()
        _ = router.swap(to: first)
        for _ in 0..<10 { _ = router.route(frame(0), level: quiet) }   // 0.5 s before the first word
        var cut = false
        for i in 0..<400 { cut = router.route(frame(i), level: speech) || cut }
        for _ in 0..<12 { cut = router.route(frame(0), level: quiet) || cut }
        #expect(cut)
        let swap = router.swap(to: second)
        #expect(swap.overlap == 0 && abs(swap.pause - 0.5) < 0.001)
        for _ in 0..<30 { _ = router.route(frame(0), level: quiet) }
        _ = router.route(frame(1), level: speech)
        // The next segment's first speech came after 0.6 s (old) + 1.5 s (new) of quiet: a paragraph break.
        let next = router.swap(to: nil)
        #expect(abs(next.pause - 2.1) < 0.001)
        await first.stop()
        await second.stop()
        #expect(b.frames.count == 31)
    }
}

@Suite struct NotesJoinTests {
    private func w(_ text: String, _ start: Double, _ end: Double) -> WordTiming { WordTiming(text: text, start: start, end: end) }

    @Test func aWordStraddlingTheCutLandsOnceWhole() {
        // Cut at 45 s with 1 s overlap: the split is at 44.5 s. "export" (44.6–45.2) is cut short on the old socket.
        let old = NotesJoin.Final(raw: "we will fix the exp", text: "We will fix the exp.",
                                  words: [w("we", 43.0, 43.2), w("will", 43.2, 43.5), w("fix", 43.5, 43.9), w("the", 44.0, 44.3),
                                          w("exp", 44.6, 45.0)])
        // The new socket starts at 44 s: it hears "the" again, and "export" whole.
        let new = NotesJoin.Final(raw: "the export is slow", text: "The export is slow.",
                                  words: [w("the", 0.0, 0.3), w("export", 0.6, 1.2), w("is", 1.3, 1.4), w("slow", 1.5, 1.8)])
        let a = NotesJoin.trim(old, leading: 0, trailing: 1, duration: 45)
        let b = NotesJoin.trim(new, leading: 1, trailing: 0, duration: 20)
        #expect(a.raw == "we will fix the" && a.text == "We will fix the" && a.words?.count == 4)
        #expect(b.raw == "export is slow" && b.text == "export is slow." && b.words?.first?.text == "export")
        #expect((a.raw + " " + b.raw).split(separator: " ").filter { $0 == "the" }.count == 1)
    }

    @Test func aWordBothDecodesTimedOnTheirOwnSideIsDroppedByTheTextRule() {
        // The old socket timed "the" before the split, the new one after it: the timing trim keeps both, and the
        // text rule the recorder runs next drops the repeat.
        let old = NotesJoin.trim(.init(raw: "we will fix the", text: "We will fix the",
                                       words: [w("we", 43.0, 43.2), w("will", 43.2, 43.5), w("fix", 43.5, 43.9), w("the", 44.2, 44.45)]),
                                 leading: 0, trailing: 1, duration: 45)
        let new = NotesJoin.trim(.init(raw: "the export is slow", text: "The export is slow.",
                                       words: [w("the", 0.45, 0.6), w("export", 0.7, 1.2), w("is", 1.3, 1.4), w("slow", 1.5, 1.8)]),
                                 leading: 1, trailing: 0, duration: 20)
        #expect(old.raw == "we will fix the" && new.raw == "the export is slow")
        #expect(NotesJoin.dedupe(new, after: old.text).text == "export is slow.")
    }

    @Test func trimmingKeepsTheTextWhenCleanUpDeletedTheWord() {
        let new = NotesJoin.Final(raw: "um the the export works", text: "The export works.",
                                  words: [w("um", 0.1, 0.2), w("the", 0.3, 0.4), w("the", 0.6, 0.7), w("export", 0.8, 1.2),
                                          w("works", 1.3, 1.6)])
        // "um" and the first "the" fall before the split; the kept raw still starts with "the", so "The" stays.
        #expect(NotesJoin.trim(new, leading: 1, trailing: 0, duration: 10).text == "The export works.")
    }

    @Test func noOverlapOrNoTimingsLeavesAFinalAlone() {
        let f = NotesJoin.Final(raw: "a b", text: "A b.", words: [w("a", 0, 0.2), w("b", 0.3, 0.5)])
        #expect(NotesJoin.trim(f, leading: 0, trailing: 0, duration: 1) == f)
        let bare = NotesJoin.Final(raw: "a b", text: "A b.")
        #expect(NotesJoin.trim(bare, leading: 1, trailing: 1, duration: 1) == bare)
    }

    @Test func withoutTimingsADuplicateFirstWordOrBigramIsDropped() {
        let bigram = NotesJoin.dedupe(.init(raw: "the export is slow", text: "The export is slow."), after: "We will fix the export")
        #expect(bigram.raw == "is slow" && bigram.text == "is slow.")
        let word = NotesJoin.dedupe(.init(raw: "export is slow", text: "Export is slow."), after: "We will fix the export.")
        #expect(word.raw == "is slow" && word.text == "is slow.")
    }

    @Test func aRepeatedWordThatIsNotAtTheJoinIsKept() {
        let f = NotesJoin.Final(raw: "we said that that works", text: "We said that that works.")
        #expect(NotesJoin.dedupe(f, after: "and then") == f)
        #expect(NotesJoin.dedupe(.init(raw: "slow", text: "Slow."), after: "it is slow") == .init(raw: "slow", text: "Slow."))
    }

    @Test func contextIsTheEndOfThePreviousFinalFromAWordStart() {
        #expect(NotesJoin.context("  Short one. ") == "Short one.")
        #expect(NotesJoin.context("") == nil)
        let long = String(repeating: "alpha beta ", count: 40) + "end"
        let c = NotesJoin.context(long)!
        #expect(c.count <= NotesJoin.contextChars && c.hasSuffix("end") && (c.hasPrefix("alpha") || c.hasPrefix("beta")))
        #expect(ClientMessage.stop(context: nil) == ClientMessage.stop)
        #expect(ClientMessage.stop(context: "We will") == #"{"context":"We will","type":"stop"}"#)
    }
}

@Suite struct NotesParagraphTests {
    private func doc(_ pauses: [TimeInterval?], texts: [String]? = nil) -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        for (i, p) in pauses.enumerated() {
            var s = NotesSegment(id: i, offset: Double(i) * 45, raw: texts?[i] ?? "part \(i)")
            s.pauseBefore = p
            d.append(s)
        }
        return d
    }

    @Test func segmentsWithoutAPauseJoinOneParagraph() {
        let d = doc([nil, 0.2, 1.9, 2.0, 0.1])
        #expect(d.transcriptParagraphs.map { $0.parts.map(\.segment) } == [[0, 1, 2], [3, 4]])
        #expect(d.transcriptParagraphs[0].offset == 0 && d.transcriptParagraphs[0].parts.map(\.offset) == [0, 45, 90])
        #expect(d.transcriptLines() == ["**[00:00:00]** part 0 part 1 part 2", "**[00:02:15]** part 3 part 4"])
    }

    @Test func aGapOrAStopBreaksTheParagraph() {
        var d = doc([nil, 0.1])
        d.append(.gap(id: 2, offset: 90, reason: "timed out"))
        var after = NotesSegment(id: 3, offset: 135, raw: "after")
        after.pauseBefore = 0.1
        d.append(after)
        var record = NotesSegment(id: 4, offset: 180, raw: "next recording")
        record.pauseBefore = nil
        d.append(record)
        #expect(d.transcriptParagraphs.map { $0.parts.map(\.segment) } == [[0, 1], [2], [3], [4]])
        #expect(d.transcriptParagraphs[1].failure == "timed out")
    }

    @Test func aSpeakerChangeBreaksTheParagraph() {
        var d = doc([nil, 0.1, 0.1])
        d.attachSpeakers([.init(slot: 0, start: 0, text: "part 0")], toSegment: 0)
        d.attachSpeakers([.init(slot: 0, start: 45, text: "part"), .init(slot: 1, start: 50, text: "1")], toSegment: 1)
        d.attachSpeakers([.init(slot: 1, start: 90, text: "part 2")], toSegment: 2)
        #expect(d.transcriptParagraphs.map(\.id) == ["0.0", "1.1"])
        #expect(d.transcriptLines() == ["**[00:00:00] Person 1:** part 0 part", "**[00:00:50] Person 2:** 1 part 2"])
    }

    @MainActor @Test func rowsAreCachedAndGrowOnlyAtTheEnd() {
        let m = NotesModel()
        var d = doc([nil, 0.1, 3])
        m.document = d
        #expect(m.transcriptRows.map(\.id) == ["0", "2"])
        var s = NotesSegment(id: 3, offset: 135, raw: "more")
        s.pauseBefore = 0.1
        d.append(s)
        m.document = d
        #expect(m.transcriptRows.map { $0.paragraph.parts.map(\.segment) } == [[0, 1], [2, 3]])
        // New labels on an old segment rebuild from there.
        d.attachSpeakers([.init(slot: 0, start: 45, text: "part 1")], toSegment: 1)
        m.document = d
        #expect(m.transcriptRows.map(\.id) == ["0", "1.0", "2"])
        #expect(m.transcriptRows.map(\.id) == m.document.transcriptParagraphs.map(\.id))
        #expect(d.firstRelabelled(since: d.labelRevision - 1) == 1 && d.firstRelabelled(since: d.labelRevision) == d.segments.count)
    }
}

@Suite struct NotesSectionTests {
    @Test func headingsRememberTheFirstSegmentTheyCameFrom() {
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 12, raw: "budget talk"))
        d.apply(NotesStructureResponse(markdown: "## Budget\n- talk", structured: true), for: d.nextStructureRequest()!)
        d.append(NotesSegment(id: 1, offset: 57, raw: "hiring talk"))
        d.apply(NotesStructureResponse(markdown: "## Budget\n- talk\n\n## **Hiring**\n- talk", structured: true),
                for: d.nextStructureRequest()!)
        #expect(d.sectionOffset("Budget") == 12 && d.sectionOffset("hiring") == 57 && d.sectionOffset("Other") == nil)
    }

    @Test func unstructuredSecondsCountWaitingSpeech() {
        var d = NotesDocument()
        for i in 0..<3 {
            var s = NotesSegment(id: i, offset: Double(i) * 40, raw: "words \(i)")
            s.end = Double(i) * 40 + 40
            d.append(s)
        }
        #expect(d.unstructuredSeconds == 120)
        d.apply(NotesStructureResponse(markdown: "- words", structured: true), for: d.nextStructureRequest()!)
        #expect(d.unstructuredSeconds == 0)
    }

    @MainActor @Test func lagChipAndLongRunNotice() {
        let m = NotesModel()
        m.state = .recording
        var d = NotesDocument()
        var s = NotesSegment(id: 0, offset: 0, raw: "words")
        s.end = 80
        d.append(s)
        m.document = d
        #expect(m.lagText == "Notes 1:20 behind")
        m.structuring = .off(.disabled)
        #expect(m.lagText == nil)
        m.elapsed = 2 * 3600 - 1
        #expect(!m.showsLongRunNotice)
        m.elapsed = 2 * 3600 + 5
        #expect(m.showsLongRunNotice && m.longRunHours == 2)
        m.keepGoing()
        #expect(!m.showsLongRunNotice)
        m.elapsed = 4 * 3600
        #expect(m.showsLongRunNotice && m.longRunHours == 4)
        m.state = .stopped
        #expect(!m.showsLongRunNotice)
    }

    @MainActor @Test func aSectionStampJumpsToTheTranscript() {
        let m = NotesModel()
        var d = NotesDocument()
        for i in 0..<3 {
            var s = NotesSegment(id: i, offset: Double(i) * 45, raw: "part \(i)")
            s.pauseBefore = i == 2 ? 5 : 0.1
            d.append(s)
        }
        m.document = d
        var tabs: [NotesTab] = []
        m.onTabChange = { tabs.append($0) }
        m.jumpToTranscript(at: 50)
        #expect(m.tab == .split && tabs == [.split] && m.highlightedParagraph == "0" && m.transcriptJump == 1)
        m.jumpToTranscript(at: 95)
        #expect(m.highlightedParagraph == "2" && tabs == [.split])
    }
}

@Suite struct NotesTimelineWindowTests {
    @Test func oldSpansArePrunedAndLookupsAreWindowed() {
        var t = SpeakerTimeline()
        t.spans = (0..<7200).map { SpeakerSpan(slot: $0 % 2, start: Double($0), end: Double($0) + 0.9) }
        t.finalizedThrough = 7200
        t.prune()
        #expect(t.spans.count == 600 && t.spans.first!.end >= 7200 - SpeakerTimeline.retained)
        let near = t.labellingSpans(near: 7000...7010)
        #expect(near.map(\.start) == Array(6998...7011).map(Double.init))
    }
}

@Suite struct NotesLongJournalTests {
    @Test func theJournalKeepsJoinsAndSectionTimesAndReadsOlderJournals() throws {
        var d = NotesDocument()
        var s = NotesSegment(id: 0, offset: 12, raw: "budget talk")
        s.end = 57
        s.pauseBefore = 0.4
        d.append(s)
        d.apply(NotesStructureResponse(markdown: "## Budget\n- talk", structured: true), for: d.nextStructureRequest()!)
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(NotesDocument.self, from: data)
        #expect(back.segments[0].end == 57 && back.segments[0].pauseBefore == 0.4 && back.sectionOffset("Budget") == 12)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["sectionOffsets"] = nil
        let older = try JSONDecoder().decode(NotesDocument.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.sectionOffsets.isEmpty && older.text == d.text)
    }
}
