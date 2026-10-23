import Darwin
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// A speaker model whose diarizer hears a scripted meeting: three people taking turns every 20 s for two hours.
final class SoakSpeakerStore: SpeakerModelStore, @unchecked Sendable {
    final class Factory: SpeakerDiarizerFactory, @unchecked Sendable {
        func makeDiarizer() -> SpeakerDiarizing {
            FakeDiarizer(script: stride(from: 0.0, to: 7300, by: 20).enumerated().map { SpeakerSpan(slot: $0.offset % 3, start: $0.element, end: $0.element + 19.5) },
                         lag: 0)
        }
    }
    var sizeText: String { "106 MB" }
    func isDownloaded() -> Bool { true }
    func hasFiles() -> Bool { true }
    func load(download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> any SpeakerDiarizerFactory { Factory() }
    func remove() throws {}
}

/// The process's physical footprint (what Activity Monitor shows as Memory), bytes.
func physFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

/// Two hours of Live Notes through the whole session on the fake clock (#66): 160 segments of about 625 characters,
/// speakers on, structuring and auto-reorganize after each commit, a typed line every ten segments, and the editor
/// replaying every change. The budgets are 2× the baselines in docs/bench.md (Live Notes session soak), measured on
/// the debug build the tests run. Memory is asserted only when the suite runs alone (`CHIRP_SOAK=1`), since other
/// suites allocate in the same process.
@MainActor
@Suite(.serialized) struct NotesSoakTests {
    static let segments = 160
    static let segmentSpeech = 44.0

    /// About 625 characters: two hours of talk is about 100 000.
    nonisolated static func finalText(_ n: Int) -> String {
        let sentences = ["We went through the budget for item \(n) and agreed it stays within the quarter.",
                         "The vendor contract needs a second review before anyone signs it.",
                         "Someone will draft the migration plan and share it by Thursday.",
                         "We will not move the launch date unless the load test fails again.",
                         "The question of hiring for support stays open until the next meeting.",
                         "Notes from the design review go into the shared folder today.",
                         "Everyone agreed that the metrics dashboard needs fewer charts.",
                         "The team asked for one more week to finish the accessibility pass.",
                         "Support tickets about sign-in dropped by a third after the last fix."]
        return sentences.joined(separator: " ")
    }

    @Test(.timeLimit(.minutes(2)))
    func aTwoHourSessionStaysWithinBudget() async {
        let health = Health(correction: "available", notesStructure: true, notesCorrection: true, notesReorganize: true)
        let h = NotesHarness(health: health, speakers: SoakSpeakerStore(), finalText: Self.finalText)
        let footprintBefore = physFootprint()
        let started = ContinuousClock.now
        await h.record()
        for i in 0..<Self.segments {
            var left = Self.segmentSpeech
            while left > 0 {
                h.engine.play(.speech, seconds: 4, buffer: 1)
                h.clock.advance(4)
                left -= 4
                await Task.yield()
            }
            h.engine.play(.pause, seconds: 0.6, buffer: 0.2)
            await h.until("cut \(i)") { h.streams.started >= i + 2 }
            // The final lands before the fake clock moves on, so its timeout never races a busy main actor.
            await h.until("segment \(i) committed") { h.document.segments.count >= i + 1 }
            h.clock.advance(1)
            if i % 10 == 9 { await h.typeAtEnd("\nmy note \(i)") }
        }
        await h.stop()
        let wall = (ContinuousClock.now - started).inSeconds

        let transcriptChars = h.document.segments.reduce(0) { $0 + $1.text.count }
        #expect(h.document.segments.count == Self.segments + 1)
        #expect(h.gaps == 0, "\(h.document.segments.compactMap(\.failure))")
        #expect(transcriptChars > 95_000)
        #expect(h.document.speakerCount == 3)
        #expect(h.recorder.state == .stopped)
        h.expectEditorInSync()
        #expect(h.text.contains("my note 159"))

        let rowsTime = ContinuousClock().measure { for _ in 0..<5 { _ = h.model.transcriptRows } }.inSeconds / 5
        let hearingTime = ContinuousClock().measure { for _ in 0..<5 { _ = h.model.hearingParts } }.inSeconds / 5
        let updates = h.editorUpdates.sorted()
        let medianUpdate = updates.isEmpty ? 0 : updates[updates.count / 2]
        let maxUpdate = updates.last ?? 0
        let syncsPerSegment = Double(h.syncs) / Double(Self.segments)
        let growthMB = Double(Int64(physFootprint()) - Int64(footprintBefore)) / 1_048_576
        let passesPerSegment = Double(h.http.structureRequests.count) / Double(Self.segments)
        print("notes soak: wall=\(wall)s segments=\(h.document.segments.count) transcriptChars=\(transcriptChars) notesChars=\(h.text.count) structure=\(h.http.structureRequests.count) reorganize=\(h.http.reorganizeRequests.count) syncs/segment=\(syncsPerSegment) editorUpdates=\(updates.count) medianUpdate=\(medianUpdate * 1000)ms maxUpdate=\(maxUpdate * 1000)ms transcriptRows=\(rowsTime * 1000)ms hearingParts=\(hearingTime * 1000)ms footprintGrowth=\(growthMB)MB")

        // 2× the baselines (docs/bench.md): counts are exact, times are medians so one slow update on a busy host
        // does not fail the run.
        #expect(syncsPerSegment < Budget.syncsPerSegment, "syncs per segment \(syncsPerSegment)")
        #expect(passesPerSegment < Budget.passesPerSegment, "structure passes per segment \(passesPerSegment)")
        #expect(medianUpdate < Budget.medianEditorUpdate, "median editor update \(medianUpdate * 1000) ms")
        #expect(rowsTime < Budget.transcriptRows, "transcriptRows \(rowsTime * 1000) ms")
        #expect(hearingTime < Budget.hearingParts, "hearingParts \(hearingTime * 1000) ms")
        if ProcessInfo.processInfo.environment["CHIRP_SOAK"] == "1" {
            #expect(growthMB < Budget.footprintGrowthMB, "footprint grew \(growthMB) MB")
        }
    }

    /// Ceilings: 2× the worst baseline in docs/bench.md › Live Notes session soak.
    enum Budget {
        static let syncsPerSegment = 15.0
        static let passesPerSegment = 2.2
        static let medianEditorUpdate = 0.020
        static let transcriptRows = 0.0009
        static let hearingParts = 0.000045
        static let footprintGrowthMB = 32.0
    }
}
