import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Long dictation (#64) through `NotesSession` and the harness: a 45 s run without a pause is cut with an overlap,
/// and the two segments read as one paragraph.
@MainActor
@Suite(.serialized) struct NotesLongSessionTests {
    @Test func aRunWithoutAPauseIsCutWithAOneSecondOverlapAndReadsAsOneParagraph() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(50)
        await h.until("first final") { h.document.segments.count == 1 }
        await h.stop()
        #expect(h.transcript == ["Segment 0.", "Segment 1."])
        let bytes = h.streams.bytesBySocket
        let perSecond = Int(PCMConverter.sampleRate) * 2
        // The second socket heard the last second of the first one again.
        #expect((bytes[0] ?? 0) + (bytes[1] ?? 0) - Int(h.recorder.elapsed * Double(perSecond)) == perSecond)
        #expect(abs(h.document.segments[1].offset - (NotesSegmenter.maxSegment - NotesSegmenter.overlap)) < 0.1)
        #expect(h.model.transcriptRows.count == 1 && h.model.transcriptRows[0].paragraph.parts.count == 2)
        h.expectEditorInSync()
    }
}
