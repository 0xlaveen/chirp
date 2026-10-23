import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Issue #18 M2: rename, merge, separate and reassign in the session, and a rename carried into the notes.
@Suite struct SpeakerEditTests {
    /// Three people: slot 5 is Person 1, slot 0 Person 2, slot 7 Person 3; notes that name two of them.
    private func document(notes: String = "## Plan\n- [ ] **Person 2** to send the spec\n- Person 20 joins in May\n- Person 1 agreed with Person 2.\n")
        -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0), text: notes)
        d.append(NotesSegment(id: 0, offset: 0, raw: "we ship friday ok", text: "We ship Friday. OK."))
        d.attachSpeakers([.init(slot: 5, start: 0, text: "We ship Friday."), .init(slot: 0, start: 2, text: "OK.")], toSegment: 0)
        d.append(NotesSegment(id: 1, offset: 10, raw: "budget is fine", text: "Budget is fine."))
        d.attachSpeakers([.init(slot: 7, start: 10, text: "Budget is fine.")], toSegment: 1)
        return d
    }

    @Test func renameFlowsIntoTranscriptExportAndPasses() throws {
        var d = document()
        d.markSaved()
        d.renameSpeaker(2, to: " Maya ")
        #expect(d.isDirty && d.roster.displayName(2) == "Maya")
        #expect(d.transcriptLines()[1] == "**[00:00:02] Maya:** OK.")
        #expect(try #require(d.nextStructureRequest()).transcript == "Person 1: We ship Friday.\nMaya: OK.\nPerson 3: Budget is fine.")
        d.renameSpeaker(2, to: "")
        #expect(d.roster.displayName(2) == "Person 2")
    }

    @Test func mergeRelabelsPastTurnsAndFutureAudioAndSeparateUndoesIt() throws {
        var d = document()
        let version = d.version
        d.renameSpeaker(1, to: "Maya")
        d.mergeSpeaker(3, into: 1)
        #expect(d.version == version)                       // names and merges never touch the notes text
        #expect(d.speakerCount == 2 && d.transcriptLines()[2] == "**[00:00:10] Maya:** Budget is fine.")
        #expect(d.roster.merged(into: 1) == [3] && d.roster.active == [1, 2])
        // Later audio from Person 3's slot is Maya's too, but stays Person 3's underneath.
        d.append(NotesSegment(id: 2, offset: 20, raw: "and the venue"))
        d.attachSpeakers([.init(slot: 7, start: 20, text: "and the venue")], toSegment: 2)
        #expect(d.segments[2].turns?[0].person == 3 && d.roster.displayName(3) == "Maya")
        #expect(try #require(d.nextStructureRequest()).transcript.hasSuffix("Maya: Budget is fine.\nMaya: and the venue"))
        d.separateSpeaker(3)
        #expect(d.speakerCount == 3 && d.roster.displayName(3) == "Person 3")
        #expect(d.transcriptLines().last == "**[00:00:20] Person 3:** and the venue")
    }

    @Test func reassignedTurnsAreManualAndNeverRelabelled() {
        var d = document()
        let revision = d.labelRevision
        #expect(d.reassignTurns([SpeakerTurnRef(segment: 0, index: 1)], to: 3) == 3)
        #expect(d.segments[0].turns?[1].person == 3 && d.segments[0].turns?[1].manual == true)
        #expect(d.labelRevision == revision + 1 && d.firstRelabelled(since: revision) == 0)
        // A later (settled) label of the same split keeps the user's person and takes the rest.
        d.attachSpeakers([.init(slot: 0, start: 0, text: "We ship Friday."), .init(slot: 5, start: 2, text: "OK.")], toSegment: 0)
        #expect(d.segments[0].turns?.map(\.person) == [2, 3])
        // One that splits it differently leaves the user's fix alone.
        d.attachSpeakers([.init(slot: 0, start: 0, text: "We ship Friday. OK.")], toSegment: 0)
        #expect(d.segments[0].turns?.map(\.person) == [2, 3])
        // New person: the next number, with no diarizer slot behind it.
        #expect(d.reassignTurns([SpeakerTurnRef(segment: 1, index: 0)], to: nil) == 4)
        #expect(d.roster.displayName(4) == "Person 4" && d.roster.slot(for: 4) == nil)
        #expect(d.reassignTurns([SpeakerTurnRef(segment: 9, index: 0)], to: 1) == nil)
    }

    @Test func turnRefsComeFromLabelledParts() {
        let d = document()
        let p = d.transcriptParagraphs
        #expect(p.map(NotesDocument.turnRefs) == [[.init(segment: 0, index: 0)], [.init(segment: 0, index: 1)], [.init(segment: 1, index: 0)]])
        #expect(SpeakerTurnRef(partID: "4") == nil)
    }

    @Test func nameRangesAreWordBounded() {
        let text = "Person 2, Person 20, xPerson 2, Person 2_x, **Person 2**, Person 2’s, Person 2"
        #expect(NotesDocument.nameRanges("Person 2", in: text).count == 4)
        #expect(NotesDocument.nameRanges("Maya", in: "Maya, Mayan, Ümaya, Maya.").count == 2)
        #expect(NotesDocument.nameRanges(" ", in: "a b").isEmpty)
    }

    @Test func replaceInNotesIsWordBoundedKeepsTheTailAndUndoes() throws {
        var d = document(notes: "## Plan\n- Person 2 owns it\n- Person 20 too")
        // An AI tail after the user's text, naming Person 2 as well.
        let r = try #require(d.nextStructureRequest())
        d.apply(NotesStructureResponse(markdown: "## Next\n- [ ] **Person 2** sends the spec", structured: true), for: r)
        let before = d.text, tail = d.tail
        #expect(d.nameCount("Person 2") == 2)
        let replaced = d.replaceSpeakerName("Person 2", with: "Maya")
        let done = try #require(replaced)
        #expect(d.text == before.replacingOccurrences(of: "Person 2 owns", with: "Maya owns").replacingOccurrences(of: "**Person 2**", with: "**Maya**"))
        #expect(d.text.contains("Person 20 too"))
        // The tail is still the AI's, with the name replaced.
        #expect(d.tail == tail.replacingOccurrences(of: "Person 2", with: "Maya"))
        #expect(done.changes.count == 2 && done.changes.allSatisfy { $0.kind == .rename })
        // The changes replay onto the old text exactly.
        #expect(done.changes.reduce(before) { $1.applied(to: $0) } == d.text)
        let reverted = d.revert(done)
        let undo = try #require(reverted)
        #expect(d.text == before && d.tail == tail)
        #expect(undo.reduce(d.text.replacingOccurrences(of: "Person 2 owns", with: "Maya owns")
            .replacingOccurrences(of: "**Person 2**", with: "**Maya**")) { $1.applied(to: $0) } == before)
        // Once the notes moved on, it is not undone.
        let replacedAgain = d.replaceSpeakerName("Person 2", with: "Maya")
        let again = try #require(replacedAgain)
        d.userEdit(NSRange(location: 0, length: 0), "x")
        #expect(d.revert(again) == nil)
        #expect(d.replaceSpeakerName("Nobody", with: "Maya") == nil && d.replaceSpeakerName("Maya", with: " ") == nil)
    }

    @Test func replaceKeepsFallbackBlocksFindable() throws {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        d.append(NotesSegment(id: 0, offset: 0, raw: "we ship", text: "We ship."))
        d.attachSpeakers([.init(slot: 0, start: 0, text: "We ship.")], toSegment: 0)
        d.freezeAll()
        #expect(d.fallbackBlocks.count == 1 && d.text.contains("Person 1: We ship."))
        let replaced = d.replaceSpeakerName("Person 1", with: "Maya")
        let done = try #require(replaced)
        #expect(d.fallbackBlocks[0].contains("Maya: We ship.") && d.text.contains(d.fallbackBlocks[0]))
        _ = d.revert(done)
        #expect(d.fallbackBlocks[0].contains("Person 1: We ship.") && d.text.contains(d.fallbackBlocks[0]))
    }

    @Test func rosterSeparateAndRawIds() {
        var r = SpeakerRoster()
        #expect(r.id(forSlot: 4) == 1 && r.id(forSlot: 2) == 2 && r.addPerson() == 3)
        r.merge(2, into: 1)
        #expect(r.id(forSlot: 2) == 2 && r.person(forSlot: 2) == 1)
        r.merge(3, into: 2)                                   // into a merged person: lands on who stands for it
        #expect(r.resolve(3) == 1 && r.merged(into: 1) == [2, 3])
        r.separate(2)
        #expect(r.resolve(2) == 2 && r.resolve(3) == 1 && r.active == [1, 2])
    }
}

/// The window's side: the chip menu's edits through the session, the banner, and the editor's undo group.
@MainActor
@Suite(.serialized) struct SpeakerEditSessionTests {
    private func harness() -> NotesHarness {
        let h = NotesHarness()
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0), text: "## Plan\n- [ ] **Person 2** sends the spec\n- Person 20 joins")
        d.append(NotesSegment(id: 0, offset: 0, raw: "we ship ok", text: "We ship. OK."))
        d.attachSpeakers([.init(slot: 0, start: 0, text: "We ship."), .init(slot: 1, start: 1, text: "OK.")], toSegment: 0)
        h.recorder.restore(d, elapsed: 2)
        return h
    }

    @Test func renameOffersTheReplaceWhichIsOneUndoGroup() throws {
        let h = harness()
        #expect(h.text == h.document.text)
        h.model.beginRename(row: "0.1", person: 2)
        #expect(h.model.renaming == SpeakerRename(row: "0.1", person: 2) && h.model.renameText.isEmpty)
        h.model.renameText = "Maya"
        h.model.commitRename()
        #expect(h.model.renaming == nil && h.document.roster.displayName(2) == "Maya")
        #expect(h.model.transcriptRows[1].chip?.name == "Maya")
        #expect(h.model.visibleSpeakerBanner?.kind == .offerReplace(old: "Person 2", new: "Maya", count: 1))
        #expect(h.model.visibleSpeakerBanner?.text == "Also replace “Person 2” with “Maya” in the notes? (1 place)")
        h.model.onSpeakerEdit(.replaceInNotes)
        #expect(h.document.text == "## Plan\n- [ ] **Maya** sends the spec\n- Person 20 joins" && h.text == h.document.text)
        #expect(h.editor.undo.undoActionName == NotesEditorCoordinator.renameAction)
        #expect(h.model.speakerBannerUndoable)
        // ⌘Z in the editor puts the name back (reported to the document like any undo).
        h.editor.undo.undo()
        #expect(h.text.contains("**Person 2**") && h.document.text == h.text)
        #expect(!h.model.speakerBannerUndoable)
        // The banner's Undo works too, while the notes are as the replace left them.
        h.model.onSpeakerEdit(.dismiss)
        h.model.onSpeakerEdit(.rename(2, to: "Maya Chen"))
        #expect(h.model.visibleSpeakerBanner == nil)                // "Maya" is not in the notes now
        h.model.onSpeakerEdit(.rename(2, to: ""))
        h.model.onSpeakerEdit(.rename(2, to: "Maya"))
        h.model.onSpeakerEdit(.replaceInNotes)
        #expect(h.text.contains("**Maya**"))
        h.model.onSpeakerEdit(.undo)
        #expect(h.document.text.contains("**Person 2**") && h.text == h.document.text && h.model.visibleSpeakerBanner == nil)
    }

    @Test func mergeAndReassignFromTheMenu() {
        let h = harness()
        h.model.onSpeakerEdit(.merge(2, into: 1))
        #expect(h.model.visibleSpeakerBanner?.text == "Merged Person 2 into Person 1.")
        #expect(h.model.transcriptRows.count == 1 && h.document.speakerCount == 1)
        h.model.onSpeakerEdit(.undo)
        #expect(h.document.speakerCount == 2 && h.model.visibleSpeakerBanner == nil)
        h.model.onSpeakerEdit(.reassign([SpeakerTurnRef(segment: 0, index: 1)], to: nil))
        #expect(h.document.segments[0].turns?[1].person == 3 && h.model.transcriptRows[1].chip?.name == "Person 3")
        // New drops the banner with the document.
        h.model.onSpeakerEdit(.merge(3, into: 1))
        h.session.reset()
        #expect(h.model.visibleSpeakerBanner == nil)
    }
}
