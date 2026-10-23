import AppKit
import Darwin
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Budgets for a two-hour session (#64): 160 segments, about 100 000 transcript characters with speakers on, and
/// 30 000 characters of notes. Times are measured on the debug build the tests run, so the bounds are the issue's
/// release targets with headroom for a loaded CI host; `docs/bench.md` has the measured numbers.
@MainActor
@Suite(.serialized) struct NotesBudgetTests {
    static let segments = 160
    /// A 2 h talk is about 18 000 words, about 100 000 characters: 625 per 45 s segment.
    static let sentence = "We looked at the vendor contract and the budget for the second quarter again today. "

    /// The session's transcript, labelled: two turns per segment, a speaker change every third one, pauses short
    /// enough that most segments join a paragraph.
    static func twoHours(labelled: Bool = true) -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        for i in 0..<segments {
            append(i, to: &d, labelled: labelled)
            // Structured as it goes, like a session: the open window stays a few segments long.
            if let r = d.nextStructureRequest() {
                d.apply(NotesStructureResponse(markdown: "## Part \(i)\n- \(r.transcript.count) characters heard", structured: true), for: r)
            }
        }
        return d
    }

    static func append(_ i: Int, to d: inout NotesDocument, labelled: Bool = true) {
        let text = String(repeating: sentence, count: 7).trimmingCharacters(in: .whitespaces) + " Segment \(i)."
        var s = NotesSegment(id: i, offset: Double(i) * 45, raw: text.lowercased(), text: text, corrected: true)
        s.end = Double(i) * 45 + 45
        s.pauseBefore = i == 0 ? nil : i % 7 == 0 ? 2.5 : 0.3
        d.append(s)
        guard labelled else { return }
        let half = text.index(text.startIndex, offsetBy: text.count / 2)
        let slot = i % 3 == 0 ? 1 : 0
        d.attachSpeakers([.init(slot: slot, start: s.offset, text: String(text[..<half])),
                          .init(slot: slot, start: s.offset + 20, text: String(text[half...]))], toSegment: i)
    }

    static let notesLine = "- **Decision:** keep the _vendor_ contract, and [ ] send the budget to finance\n"
    static func notes(_ chars: Int = 30_000) -> String {
        var out = "", k = 0
        while out.utf16.count < chars {
            out += "## Section \(k)\n" + String(repeating: notesLine, count: 6) + "\n"
            k += 1
        }
        return out
    }

    private func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    @Test func theFixtureIsTwoHoursLong() {
        let d = Self.twoHours()
        let chars = d.segments.reduce(0) { $0 + $1.text.count }
        #expect(d.segments.count == 160 && chars > 95_000 && chars < 110_000)
        #expect(d.segments.last!.end! >= 7200)
    }

    @Test func aPartialOrANewSegmentRedoesOnlyWhatChanged() {
        let model = NotesModel()
        model.state = .recording
        var d = Self.twoHours()
        model.document = d
        let clock = ContinuousClock()
        let full = clock.measure { _ = model.transcriptRows }
        // A partial: only the live text changes. The rows come from the cache.
        var partial = Duration.zero
        for i in 0..<50 {
            d.livePartial = "and the next words \(i)"
            model.document = d
            partial += clock.measure {
                _ = model.transcriptRows
                _ = model.hearingParts
                _ = model.lagText
            }
        }
        // A new segment: the last paragraph is walked again, not the session.
        Self.append(Self.segments, to: &d)
        model.document = d
        let grown = clock.measure { _ = model.transcriptRows }
        #expect(model.transcriptRows.map(\.id) == d.transcriptParagraphs.map(\.id))
        #expect(ms(partial) / 50 < 1, "per partial \(ms(partial) / 50) ms")
        #expect(ms(grown) < max(5, ms(full) / 4), "new segment \(ms(grown)) ms, full \(ms(full)) ms")
        print("budget rows full_ms=\(ms(full)) partial_ms=\(ms(partial) / 50) segment_ms=\(ms(grown))")
    }

    @Test func restylesStayWithinBudgetAtThirtyThousandCharacters() {
        let h = NotesEditorTests.Harness(typed: Self.notes())
        let storage = h.editor.textView.textStorage!
        #expect(storage.length >= 30_000)
        // The best of a few runs: other suites share the host in a full run.
        func best(_ body: () -> Void) -> Duration { (0..<3).map { _ in ContinuousClock().measure(body) }.min()! }
        let whole = best { NotesEditorStyle.restyle(storage) }
        // An append: the AI tail at the end (one section).
        let tail = NSRange(location: storage.length - 600, length: 600)
        let append = best { NotesEditorStyle.restyle(storage, range: tail) }
        // A reorganize replaces one 3500-character scope; only it is restyled.
        let scope = NSRange(location: storage.length / 2, length: 3500)
        let reorganize = best { NotesEditorStyle.restyle(storage, range: scope) }
        print("budget restyle whole_ms=\(ms(whole)) append_ms=\(ms(append)) scope_ms=\(ms(reorganize))")
        #expect(ms(append) <= 5, "append restyle \(ms(append)) ms")
        #expect(ms(reorganize) <= 50, "scope restyle \(ms(reorganize)) ms")
        // Only a load (New, a resync) restyles everything now; on this debug build that only guards against a
        // quadratic restyle (the release numbers are in docs/bench.md).
        #expect(ms(whole) <= 600, "whole restyle \(ms(whole)) ms")
    }

    @Test func speakerLookupsStayWindowedOverTwoHours() {
        var t = SpeakerTimeline()
        // About one span per 1.5 s of talk, finalized as it goes.
        for i in 0..<4800 {
            t.spans.append(SpeakerSpan(slot: i % 3, start: Double(i) * 1.5, end: Double(i) * 1.5 + 1.4))
            t.finalizedThrough = Double(i) * 1.5 + 1.5
            t.prune()
        }
        #expect(t.spans.count <= Int(SpeakerTimeline.retained / 1.5) + 1)
        let clock = ContinuousClock()
        let lookup = clock.measure { for _ in 0..<160 { _ = t.labellingSpans(near: 7150...7195) } }
        print("budget timeline spans=\(t.spans.count) lookup_ms=\(ms(lookup) / 160)")
        #expect(ms(lookup) / 160 < 5, "lookup \(ms(lookup) / 160) ms")
    }

    /// The whole session through the recorder: 160 segments over rolling sockets, structuring after each, speakers
    /// on (scripted). Resident memory is asserted only when this suite runs alone (`CHIRP_SOAK=1`): in a full run,
    /// other suites allocate in the same process.
    @Test func aTwoHourSessionThroughTheRecorder() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        let text = String(repeating: Self.sentence, count: 7).trimmingCharacters(in: .whitespaces)
        for i in 0..<Self.segments { server.script(i, .init(finalText: text + " Segment \(i).")) }
        let stub = PassStub(), clock = ManualClock()
        stub.structureReply = { r in NotesStructureResponse(markdown: "## Part\n- \(r.transcript.count) characters", structured: true) }
        let config = ServerConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let r = NotesRecorder(makeSession: { StreamSession(config: config, options: $0) },
                              structure: { try await stub.structure($0) }, reorganize: { try await stub.reorganize($0) },
                              now: { clock.now }, sleep: { await clock.sleep($0) },
                              options: StartOptions(client: "mac", correction: true), structuring: true, autoReorganize: false,
                              health: Health(correction: "available", notesStructure: true, notesReorganize: true))
        let script = (0..<(Self.segments * 3)).map { SpeakerSpan(slot: $0 % 2, start: Double($0) * 0.4, end: Double($0) * 0.4 + 0.35) }
        r.speakers = FakeDiarizer(script: script, lag: 0)
        let frame = Data(count: 1600)
        let before = Self.footprint()
        r.start()
        let deadline = Date().addingTimeInterval(120)
        while r.state != .recording, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        for i in 0..<Self.segments {
            for _ in 0..<20 { r.handleFrame(frame, level: Level(peak: 0.5, rms: 0.2)) }
            await r.cut()
            // The final comes over the socket in real time; only then does fake time move, for the pass timer
            // (moving it earlier would trip the 25 s final deadline).
            while r.document.segments.count < i + 1, Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
            clock.advance(Double(NotesRecorder.minInterval))
            while r.passInFlight || r.labellingCount > 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        }
        if r.document.segments.count < Self.segments {
            Issue.record("stuck: state=\(r.state) segments=\(r.document.segments.count) finalizing=\(r.finalizingCount) pass=\(r.passInFlight) labelling=\(r.labellingCount) structuring=\(r.structuring) sockets=\(server.started)")
        }
        await r.stop()
        let grown = Self.footprint() - before
        #expect(r.document.segments.count == Self.segments + 1 && r.state == .stopped)
        #expect(r.document.segments.reduce(0) { $0 + $1.text.count } > 95_000)
        print("budget soak segments=\(r.document.segments.count) footprint_growth_mb=\(grown / 1_000_000)")
        if ProcessInfo.processInfo.environment["CHIRP_SOAK"] != nil {
            #expect(grown < 50_000_000, "resident memory grew \(grown / 1_000_000) MB")
        }
    }

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
