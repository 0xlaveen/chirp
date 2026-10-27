import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

// Re-transcribe in the Mac window (#287 M): the real `NotesSession` and notes library on disk, real kept AAC clips,
// scripted sockets. The consent offer, apply and Undo, Cancel leaving note.json byte for byte, an old server, and the
// Off switch hiding every entry point.

@MainActor
@Suite(.serialized) struct NotesRetranscribeSessionTests {
    static let health = Health(correction: "available", notesStructure: true, notesCorrection: true, notesContext: true,
                               notesRetranscribe: true)

    /// A stored note with three spoken segments and their kept audio (0.6 s of tone each), opened in the session.
    private func harness(health: Health? = NotesRetranscribeSessionTests.health) async throws -> (NotesHarness, UUID, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-retranscribe-\(UUID().uuidString)", isDirectory: true)
        let library = NotesLibrary(store: NotesLibraryStore(directory: dir))
        let h = NotesHarness(health: health, library: library)
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        d.userEdit(NSRange(location: 0, length: 0), "## My notes\n- typed by hand\n")
        for (i, offset) in [0.0, 0.6, 1.2].enumerated() {
            var s = NotesSegment(id: i, offset: offset, raw: "wrong text", text: "WRONG TEXT")
            s.end = offset + 0.6
            if i > 0 { s.pauseBefore = 0.1 }
            d.append(s)
        }
        d.markSaved()
        try await library.write(NotesJournalRecord(document: d, elapsed: 1.8))
        let tone = (0..<9600).map { Int16(sin(Double($0) * 0.2) * 8000) }.withUnsafeBufferPointer { Data(buffer: $0) }
        for i in 0..<3 {
            try await library.keepAudio(d.id, segment: i, frames: [tone], offset: Double(i) * 0.6, sampleRate: 16_000)
        }
        try await h.session.openNote(d.id)
        await h.until("kept audio") { !h.model.keptAudio.isEmpty }
        return (h, d.id, dir)
    }

    private func noteFile(_ dir: URL, _ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString).appendingPathComponent("note.json") }

    @Test func theSheetSaysWhatGoesWhereThenTheRunAppliesOnceAndUndoes() async throws {
        let (h, id, dir) = try await harness()
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = h.session.window
        #expect(w.canRetranscribe(h.model))
        let items = NotesCommand.items(for: h.model, library: w, windowIsKey: true)
        #expect(items.first { $0.command == .retranscribe }?.hidden == false)
        #expect(items.first { $0.command == .restoreTranscript }?.hidden == true)

        w.onRetranscribe(id, nil)
        await h.until("the offer") { w.retranscribeOffer != nil }
        let offer = try #require(w.retranscribeOffer)
        #expect(offer.clips == 3 && offer.supported && offer.segments == 3 && offer.withoutAudio == 0 && offer.segment == nil)
        #expect(abs(offer.audio - 1.8) < 0.01 && offer.local && !offer.debugRetention && !offer.rebuild)
        #expect(h.document.segments.allSatisfy { $0.text == "WRONG TEXT" })

        w.onRetranscribeStart(offer)
        await h.until("the run") { w.retranscribeRun == nil && h.document.previousTranscript != nil }
        #expect(h.transcript == ["Segment 0.", "Segment 1.", "Segment 2."])
        #expect(h.document.segments.allSatisfy { $0.engine == "scripted" })
        #expect(h.document.text == "## My notes\n- typed by hand\n")
        #expect(w.toast?.text == NotesRetranscribeText.updated && w.toast?.action == .transcript(id))
        #expect(h.streams.started == 3)
        #expect(w.canRestoreTranscript(h.model))

        // Show changes lists the three segments; Undo swaps the old words back, and that is what the library keeps.
        w.onShowTranscriptChanges(id)
        await h.until("the changes") { w.transcriptChanges != nil }
        #expect(w.transcriptChanges?.rows.map(\.segment) == [0, 1, 2])
        w.onRestoreTranscript(id)
        await h.until("undo") { h.document.segments.allSatisfy { $0.text == "WRONG TEXT" } }
        h.session.journal.flush()
        await h.session.journal.settle()
        let stored = try await h.session.library!.record(id).document
        #expect(stored.segments == h.document.segments && stored.previousTranscript?.segments.first?.text == "Segment 0.")
    }

    @Test func cancelLeavesTheNoteByteForByte() async throws {
        let (h, id, dir) = try await harness()
        defer { try? FileManager.default.removeItem(at: dir) }
        h.session.journal.flush()
        await h.session.journal.settle()
        let before = try Data(contentsOf: noteFile(dir, id))
        h.streams.script(1, SocketScript(stop: .stall))
        let w = h.session.window
        w.onRetranscribe(id, nil)
        await h.until("the offer") { w.retranscribeOffer != nil }
        w.onRetranscribeStart(try #require(w.retranscribeOffer))
        await h.until("the second clip") { h.streams.started == 2 }
        // The transcript is read-only meanwhile, and Continue recording waits.
        #expect(w.isRetranscribing(id) && !w.canRetranscribe(h.model))
        h.session.toggle(fromHotkey: false)
        #expect(!h.recorder.state.isActive)
        w.onRetranscribeCancel()
        await h.until("the cancel") { w.retranscribeRun == nil }
        #expect(w.toast?.text == NotesRetranscribeText.cancelled)
        // Nothing wrote the note: whatever disk work is queued finishes, and the file is as it was.
        await h.settle()
        await h.session.journal.settle()
        #expect(try Data(contentsOf: noteFile(dir, id)) == before)
        #expect(h.document.previousTranscript == nil && h.streams.started == 2)
    }

    @Test func anOldServerAsksForAnUpdateAndTheOffSwitchHidesEverything() async throws {
        let (h, id, dir) = try await harness(health: Health(correction: "available", notesStructure: true, notesCorrection: true))
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = h.session.window
        w.onRetranscribe(id, nil)
        await h.until("the offer") { w.retranscribeOffer != nil }
        #expect(w.retranscribeOffer?.supported == false)
        #expect(NotesRetranscribeText.update(local: true) == "Update Chirp on this Mac to re-transcribe")
        w.retranscribeOffer = nil

        h.prefs.notesAllowRetranscribe = false
        h.session.retranscribeSettingChanged()
        #expect(!w.canRetranscribe(h.model))
        #expect(NotesCommand.items(for: h.model, library: w, windowIsKey: true).first { $0.command == .retranscribe }?.hidden == true)
        w.onRetranscribe(id, nil)
        await h.settle()
        #expect(w.retranscribeOffer == nil)
    }

    @Test func copyReadsAsSpecified() {
        #expect(NotesRetranscribeText.body(audio: 490, clips: 40, local: true)
                == "Chirp sends this note’s kept audio (8 min 10 s, 40 clips) to Chirp on this Mac. It is transcribed in memory there and not kept. Nothing else receives it.")
        #expect(NotesRetranscribeText.progress(NotesRetranscribeProgress(done: 12, total: 40, audioDone: 92, audioTotal: 490))
                == "Re-transcribing · 12 of 40 · 1:32 of 8:10")
        #expect(NotesRetranscribeText.finished(updated: 38, of: 40) == "38 of 40 updated. 2 kept their old text.")
        #expect(NotesRetranscribeText.finished(updated: 40, of: 40) == "Transcript updated")
        #expect(NotesRetranscribeText.withoutAudio(3, of: 43) == "3 of 43 segments have no kept audio and keep their current text.")
        #expect(NotesRetranscribeText.oneClip(32, local: false) == "Send this 0:32 clip to your Chirp server to transcribe it again?")
        #expect(NotesRetranscribeText.waiting(local: false) == "Waiting for your Chirp server…")
    }
}
