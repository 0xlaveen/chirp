import ChirpCore
import ChirpIOSCore
import Foundation
import Testing
@testable import ChirpIOS

/// Re-transcribe from kept audio (#287 I) through the controller: real sealed clips decoded in memory, synthetic sockets.
extension LiveNotesControllerTests {
    /// One second of a quiet tone, as the microphone would hand it over (16 kHz mono PCM16).
    static let tone: Data = {
        let samples = (0..<16_000).map { Int16(2_000 * sin(Double($0) * 2 * .pi * 440 / 16_000)) }
        return samples.withUnsafeBytes { Data($0) }
    }()

    /// A stopped note with two kept clips whose transcript reads "WRONG TEXT": the first segment has two people, one
    /// named Maya, and its second turn was reassigned to her by hand. Opened in the controller.
    func seedRetranscribeNote(_ f: Fixture) async throws -> UUID {
        var document = NotesDocument(startedAt: Date(timeIntervalSince1970: 1_760_000_000), text: "## My notes\n\n- typed by me")
        var first = NotesSegment(id: 0, offset: 0, raw: "wrong text", text: "WRONG TEXT")
        first.end = 1.2
        document.append(first)
        document.attachServerTurns([ServerTurn(speaker: 0, start: 0, text: "WRONG", raw: "wrong"),
                                    ServerTurn(speaker: 1, start: 0.5, text: "TEXT", raw: "text")], generation: "seed", toSegment: 0)
        document.renameSpeaker(2, to: "Maya")
        document.append(NotesSegment(id: 1, offset: 1.2, raw: "wrong text", text: "WRONG TEXT"))
        let library = try #require(f.notes.library)
        try await library.write(NotesJournalRecord(document: document, elapsed: 3, writtenAt: Date()))
        try await library.keepAudio(document.id, segment: 0, frames: [Self.tone], offset: 0, sampleRate: 16_000)
        try await library.keepAudio(document.id, segment: 1, frames: [Self.tone], offset: 1.2, sampleRate: 16_000)
        await f.notes.ready()
        await f.notes.settleJournal()
        await f.notes.open(document.id)
        await f.notes.refreshAudio()
        #expect(f.notes.document.id == document.id)
        return document.id
    }

    /// Audio files (any decoder or encoder scratch) in the temporary folder.
    var temporaryAudio: Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { ["m4a", "caf", "wav", "aac", "pcm"].contains(($0 as NSString).pathExtension.lowercased()) })
    }

    @Test func retranscribeAppliesKeepsNamesAndUndoRoundTrips() async throws {
        let f = try fixture(retranscribe: { SyntheticTransport(automatic: true) }); defer { f.clean() }
        let id = try await seedRetranscribeNote(f)
        let before = f.notes.document
        let audioBefore = temporaryAudio
        #expect(f.notes.canRetranscribe && !f.notes.canRestoreTranscript)

        await f.notes.offerRetranscribe()
        let offer = try #require(f.notes.retranscribeOffer)
        #expect(offer.clips == 2 && offer.supported && offer.reachable && offer.canSend && !offer.rebuild)
        #expect(NotesRetranscribeCopy.body(audio: offer.audio, clips: offer.clips)
            == "Chirp sends this note’s kept audio (2 s, 2 clips) to Chirp on your computer. It is transcribed in memory there and not kept. Nothing else receives it.")
        f.notes.startRetranscribe(offer)
        #expect(f.notes.isRetranscribing && !f.notes.canRetranscribe)
        try await eventually("applied") { f.notes.retranscribeRun == nil && f.notes.retranscribeToast != nil }

        #expect(f.notes.retranscribeToast?.text == "Transcript updated" && f.notes.retranscribeToast?.action == .restoreTranscript)
        let after = f.notes.document
        #expect(after.segments.map(\.text) == ["Synthetic words again.", "Synthetic words again."])
        #expect(after.segments.allSatisfy { $0.engine == "parakeet-mlx:tdt-0.6b-v3" })
        // Who spoke when is untouched: the same turns, people and name; only their words changed.
        #expect(after.segments[0].turns?.map(\.person) == before.segments[0].turns?.map(\.person))
        #expect(after.roster.displayName(2) == "Maya" && after.text == before.text)
        // Each word goes to the turn its midpoint falls in (0.2 s, then 0.6 s and 1.0 s after Maya's turn at 0.5 s).
        #expect(after.segments[0].turns?.map(\.text) == ["Synthetic", "words again."])
        // Every clip went as a re-transcribe with word timings and no speaker session.
        let starts = f.values.starts.filter { $0.contains(#""retranscribe":true"#) }
        #expect(starts.count == 2 && starts.allSatisfy { $0.contains(#""word_timings":true"#) && !$0.contains("speakers") })
        // Sealed clips are decoded in memory: nothing new in the temporary folder.
        #expect(temporaryAudio.subtracting(audioBefore).isEmpty)
        // The previous version is stored with the note.
        await f.notes.settleJournal()
        let stored = try await f.store.libraryStore.record(id).document
        #expect(stored.previousTranscript?.segments.map(\.text) == ["WRONG TEXT", "WRONG TEXT"])
        #expect(stored.segments.map(\.text) == after.segments.map(\.text))

        // Undo puts the old words back (people kept), and doing it again swaps the new ones back in.
        #expect(f.notes.canRestoreTranscript)
        f.notes.restorePreviousTranscript()
        #expect(f.notes.document.segments.map(\.text) == ["WRONG TEXT", "WRONG TEXT"])
        #expect(f.notes.document.segments[0].turns == before.segments[0].turns)
        #expect(f.notes.retranscribeToast?.text == "Previous transcript restored")
        f.notes.restorePreviousTranscript()
        #expect(f.notes.document.segments.map(\.text) == after.segments.map(\.text))
    }

    @Test func cancelDropsEverythingStaged() async throws {
        var made: [SyntheticTransport] = []
        let f = try fixture(retranscribe: {
            let t = SyntheticTransport(automatic: true)
            t.holdsFinal = made.count > 0
            made.append(t)
            return t
        }); defer { f.clean() }
        let id = try await seedRetranscribeNote(f)
        await f.notes.settleJournal()
        let stored = try await f.store.libraryStore.record(id).document
        await f.notes.offerRetranscribe()
        f.notes.startRetranscribe(try #require(f.notes.retranscribeOffer))
        try await eventually("first clip done, second in flight") { f.notes.retranscribeRun?.progress.done == 1 && made.count == 2 }
        #expect(f.notes.retranscribeRun?.text == "Re-transcribing · 1 of 2 · 0:01 of 0:02")
        f.notes.cancelRetranscribe()
        try await eventually("cancelled") { f.notes.retranscribeRun == nil }
        #expect(f.notes.retranscribeToast?.text == "Cancelled. Nothing changed.")
        #expect(f.notes.document.segments.map(\.text) == ["WRONG TEXT", "WRONG TEXT"] && f.notes.document.previousTranscript == nil)
        // The in-flight clip got `cancel`, and the stored note is exactly as before.
        #expect(made[1].sent.contains { if case .string(let s) = $0 { s.contains(#""type":"cancel""#) } else { false } })
        await f.notes.settleJournal()
        #expect(try await f.store.libraryStore.record(id).document == stored)
    }

    @Test func backgroundPausesAfterTheClipInFlightAndResumesInFront() async throws {
        var made: [SyntheticTransport] = []
        let f = try fixture(retranscribe: {
            let t = SyntheticTransport(automatic: true)
            t.holdsFinal = made.isEmpty
            made.append(t)
            return t
        }); defer { f.clean() }
        _ = try await seedRetranscribeNote(f)
        await f.notes.offerRetranscribe()
        f.notes.startRetranscribe(try #require(f.notes.retranscribeOffer))
        try await eventually("first clip in flight") { made.count == 1 && made[0].sent.contains { if case .string(let s) = $0 { s.contains(#""type":"stop""#) } else { false } } }

        f.notes.setBackground(true)
        #expect(f.values.backgroundTasks == 1)
        made[0].releaseFinal()
        try await eventually("paused") { f.notes.retranscribeRun?.paused == true }
        #expect(f.notes.retranscribeRun?.text == "Paused. Open Chirp to finish.")
        #expect(f.notes.retranscribeRun?.progress.done == 1 && made.count == 1, "The next clip waits for the foreground")
        #expect(f.values.backgroundEnded == 1, "The background task ends once nothing is in flight")

        f.notes.setBackground(false)
        try await eventually("finished in front") { f.notes.retranscribeRun == nil && f.notes.retranscribeToast?.text == "Transcript updated" }
        #expect(made.count == 2 && f.notes.document.segments.allSatisfy { $0.text == "Synthetic words again." })
    }

    @Test func anOlderServerIsAskedToUpdateAndNothingIsSent() async throws {
        var health = LiveNotesController.syntheticHealth
        health.notesRetranscribe = nil
        let f = try fixture(health: health, retranscribe: { SyntheticTransport(automatic: true) }); defer { f.clean() }
        _ = try await seedRetranscribeNote(f)
        await f.notes.offerRetranscribe()
        let offer = try #require(f.notes.retranscribeOffer)
        #expect(!offer.supported && !offer.canSend)
        f.notes.startRetranscribe(offer)
        #expect(f.notes.retranscribeRun == nil && f.values.transports.isEmpty)
    }

    @Test func debugRetentionAndTheOffSwitch() async throws {
        var health = LiveNotesController.syntheticHealth
        health.debugRetention = true
        let f = try fixture(health: health, retranscribe: {
            let t = SyntheticTransport(automatic: true); t.holdsFinal = true; return t
        }); defer { f.clean() }
        _ = try await seedRetranscribeNote(f)
        await f.notes.offerRetranscribe()
        let offer = try #require(f.notes.retranscribeOffer)
        #expect(offer.debugRetention && offer.canSend)

        // Off hides every entry point and stops a run: nothing applies.
        f.notes.startRetranscribe(offer)
        #expect(f.notes.isRetranscribing)
        f.notes.setAllowRetranscribe(false)
        try await eventually("stopped") { f.notes.retranscribeRun == nil }
        #expect(!f.notes.canRetranscribe && f.notes.document.previousTranscript == nil)
        await f.notes.offerRetranscribe()
        #expect(f.notes.retranscribeOffer == nil)
        f.notes.setAllowRetranscribe(true)
        #expect(f.notes.canRetranscribe && f.notes.preferences.allowRetranscribe)
    }

    @Test func rebuildReplacesTheBodyAsOneUndoableChange() async throws {
        let f = try fixture(retranscribe: { SyntheticTransport(automatic: true) }); defer { f.clean() }
        _ = try await seedRetranscribeNote(f)
        let body = f.notes.document.text
        await f.notes.offerRetranscribe()
        var offer = try #require(f.notes.retranscribeOffer)
        #expect(offer.rebuildAvailable)
        offer.rebuild = true
        f.notes.startRetranscribe(offer)
        try await eventually("rebuilt") { f.notes.retranscribeToast?.text == "Notes rebuilt" }
        #expect(f.notes.document.text.hasPrefix("## Synthetic notes") && f.notes.document.text.contains("Synthetic words again."))
        #expect(f.notes.snapshots.latest?.rebuild == true && f.notes.preferences.retranscribeRebuild)
        #expect(f.notes.undoOrganize())
        #expect(f.notes.document.text == body)
    }
}
