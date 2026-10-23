import AVFoundation
import ChirpCore
import ChirpIOSCore
import Foundation
import Testing
@testable import ChirpIOS

@Suite("Long dictation segmenter")
struct DictationSegmenterTests {
    func run(_ s: inout DictationSegmenter, seconds: Double, rms: Float) -> Double? {
        var t = 0.0
        while t < seconds - 1e-9 {
            t += 0.1
            if s.feed(rms: rms, duration: 0.1) { return s.elapsed }
        }
        return nil
    }
    @Test func neverCutsBefore45Seconds() {
        var s = DictationSegmenter()
        #expect(run(&s, seconds: 44.9, rms: 0) == nil)
    }
    @Test func cutsAtTheFirstPauseAfter45Seconds() throws {
        var s = DictationSegmenter()
        #expect(run(&s, seconds: 50, rms: 0.2) == nil)
        let at = try #require(run(&s, seconds: 1, rms: 0))
        #expect(abs(at - 50.6) < 0.05, "0.6 s of quiet ends the segment")
    }
    @Test func relaxesAfter70AndAlwaysCutsAt90() throws {
        var s = DictationSegmenter()
        #expect(run(&s, seconds: 72, rms: 0.2) == nil)
        let relaxed = try #require(run(&s, seconds: 1, rms: 0))
        #expect(abs(relaxed - 72.3) < 0.05)
        var hard = DictationSegmenter()
        let at = try #require(run(&hard, seconds: 100, rms: 0.2))
        #expect(abs(at - 90) < 0.05)
    }
    @Test func rmsOfPCM16() {
        var loud = Data(); for _ in 0..<160 { withUnsafeBytes(of: Int16(16384).littleEndian) { loud.append(contentsOf: $0) } }
        #expect(abs(DictationSegmenter.rms(pcm16: loud) - 0.5) < 0.001)
        #expect(DictationSegmenter.rms(pcm16: Data(count: 320)) == 0)
    }
    @Test func joinerAddsOneSpaceOnlyWhereNeeded() {
        #expect(LongText.joiner(after: "") == "")
        #expect(LongText.joiner(after: "One.") == " ")
        #expect(LongText.joiner(after: "One. ") == "")
        #expect(LongText.join(["One.", "Two.", "Three"]) == "One. Two. Three")
    }
}

@Suite("Capture hand-off between segments")
struct CaptureCutTests {
    @Test func everyFrameGoesToExactlyOneSegmentInOrder() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        func buffer() throws -> AVAudioPCMBuffer {
            let value = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)); value.frameLength = 1600
            if let data = value.floatChannelData?[0] { for i in 0..<1600 { data[i] = 0.1 } }
            return value
        }
        func bytes(_ t: SyntheticTransport) -> Int { t.sent.reduce(0) { if case .data(let d) = $1 { $0 + d.count } else { $0 } } }
        let first = SyntheticTransport(), second = SyntheticTransport()
        let a = StreamSession(transport: first, options: StartOptions()), b = StreamSession(transport: second, options: StartOptions())
        await a.open(); await b.open()
        let sink = CaptureSink(); sink.configure(format: format)
        try sink.begin(a, onFailure: {}, onLimit: {}, onCut: {})
        sink.ready()
        sink.receive(try buffer())
        sink.cut(to: b)
        sink.receive(try buffer()); sink.receive(try buffer())
        try await Task.sleep(for: .milliseconds(50))
        #expect(bytes(first) == 3200 && bytes(second) == 0, "The new segment's audio waits for its Ready")
        sink.ready()
        try await Task.sleep(for: .milliseconds(50))
        #expect(bytes(first) == 3200 && bytes(second) == 6400)
    }
}

extension SessionCoordinatorTests {
    func push(_ f: Fixture, _ index: Int, _ json: String) { f.values.transports[index].push(json) }
    func rolled(_ f: Fixture) async throws {
        try await f.model.begin(source: .keyboard)
        try await ready(f)
        push(f, 0, #"{"type":"partial","seq":1,"text":"first part","stable":""}"#)
        try await eventually { f.model.text == "first part" }
        f.model.rollOver()
        try await eventually { f.values.transports.count == 2 }
        push(f, 1, #"{"type":"ready","session":"synthetic","debug_retention":false}"#)
        try await Task.sleep(for: .milliseconds(20))
    }

    @Test func longDictationLandsSegmentsInOrderForTheKeyboard() async throws {
        let f = try await fixture(); defer { f.clean() }
        try f.stores.history.setEnabled(true)
        try await rolled(f)
        let id = try #require(try keyboardView(f).state()?.utteranceID)
        #expect(f.values.transports[0].sent.contains { if case .string(let v) = $0 { v == ClientMessage.stop } else { false } })
        push(f, 1, #"{"type":"partial","seq":1,"text":"second","stable":""}"#)
        try await eventually { f.model.text == "second" }
        #expect(f.model.earlierText == "first part" && f.model.phase == .listening)
        push(f, 0, #"{"type":"final","text":"First part.","raw":"first part"}"#)
        try await eventually { f.model.earlierText == "First part." }
        f.model.stopDictation()
        push(f, 1, #"{"type":"final","text":"Second part.","raw":"second part"}"#)
        try await eventually { f.model.phase == .finished }
        let results = try keyboardView(f).takeResults(generation: try #require(try keyboardView(f).state()).generation, utteranceID: id)
        let shape = results.map { "\($0.kind.rawValue)|\($0.segment ?? 0)|\($0.text)" }
        // Partials are replaceable snapshots on the bridge; finals for each segment are kept in order.
        #expect(shape == ["final|0|First part.", "partial|1| second", "final|1| Second part."], "\(shape)")
        #expect(try f.stores.history.entries().first?.text == "First part. Second part.")
        f.model.copy()
        #expect(f.values.copied == ["First part. Second part."])
    }

    @Test func aLaterFinalWaitsForTheEarlierSegment() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await rolled(f)
        f.model.stopDictation()
        push(f, 1, #"{"type":"final","text":"Second."}"#)
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.model.phase != .finished, "The dictation completes only once earlier segments land")
        push(f, 0, #"{"type":"final","text":"First."}"#)
        try await eventually { f.model.phase == .finished }
        #expect(f.model.earlierText == "First." && f.model.text == "Second.")
    }

    @Test func anEarlierSegmentThatFailsKeepsWhatItHeard() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await rolled(f)
        f.values.transports[0].drop()
        try await eventually { f.model.earlierText == "first part" && f.model.notice.contains("Kept what was heard") }
        #expect(f.model.phase == .listening && f.model.armed, "The dictation carries on")
        f.model.stopDictation()
        push(f, 1, #"{"type":"final","text":"Rest."}"#)
        try await eventually { f.model.phase == .finished }
        #expect(f.model.earlierText == "first part" && f.model.text == "Rest.")
    }

    @Test func cancelDiscardsSegmentsThatHaveNotLanded() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await rolled(f)
        f.model.cancelDictation()
        #expect(f.model.phase == .armed && f.model.earlierText.isEmpty)
        push(f, 0, #"{"type":"final","text":"Must not land"}"#)
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.model.earlierText.isEmpty && f.model.text.isEmpty)
    }
}
