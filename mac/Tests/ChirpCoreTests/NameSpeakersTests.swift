import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Issue #247 item 3a: the Name speakers sheet's model (who it lists, what Done asks for, the names it offers), its
/// one edit through the session, and the "Who was speaking?" line after Stop.
@MainActor
@Suite(.serialized) struct NameSpeakersTests {
    private static let notes = "## Plan\n- [ ] **Person 2** sends the spec\n- Person 3 books the review\n- Person 20 joins\n- Person 2 agreed with Person 3."

    /// Three people (slots 5, 0, 7 → Person 1, 2, 3) over two segments, and notes that name two of them.
    private func document(text: String = notes) -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0), text: text)
        d.append(NotesSegment(id: 0, offset: 0, raw: "we ship friday ok", text: "We ship Friday. OK."))
        d.attachSpeakers([.init(slot: 5, start: 0, text: "We ship Friday."), .init(slot: 0, start: 2, text: "OK.")], toSegment: 0)
        d.append(NotesSegment(id: 1, offset: 10, raw: "budget is fine", text: "Budget is fine."))
        d.attachSpeakers([.init(slot: 7, start: 10, text: "Budget is fine.")], toSegment: 1)
        return d
    }

    private func harness() -> NotesHarness {
        let h = NotesHarness()
        h.recorder.restore(document(), elapsed: 12)
        h.model.state = .stopped
        return h
    }

    // MARK: who the sheet lists

    @Test func theSheetListsThePeopleWhoSpokeNotTheMicrophoneNorMergedAwayOnes() {
        var d = document()
        #expect(d.namableSpeakers == [1, 2, 3] && d.unnamedSpeakers == [1, 2, 3])
        d.renameSpeaker(2, to: "Maya")
        #expect(d.unnamedSpeakers == [1, 3] && d.namedSpeakers == ["Maya"])
        d.mergeSpeaker(3, into: 1)
        #expect(d.namableSpeakers == [1, 2] && d.unnamedSpeakers == [1])
        d.renameSpeaker(1, to: "  ")
        #expect(d.unnamedSpeakers == [1])
        // A call's microphone side is "You": never asked for.
        var call = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        call.append(NotesSegment(id: 0, offset: 0, raw: "hi there", text: "Hi there."))
        call.attachSpeakers([.init(slot: SpeakerRoster.youSlot, start: 0, text: "Hi."), .init(slot: 0, start: 1, text: "Hello.")], toSegment: 0)
        #expect(call.namableSpeakers.count == 1 && call.unnamedSpeakers == call.namableSpeakers && call.namedSpeakers.isEmpty)
        #expect(NotesDocument().namableSpeakers.isEmpty)
    }

    @Test func theNamesNotesUsedAreDistinctAndKeepTheirOrder() {
        var d = document()
        d.renameSpeaker(1, to: "Maya")
        d.renameSpeaker(2, to: "maya")
        d.renameSpeaker(3, to: "Theo Park")
        #expect(d.namedSpeakers == ["Maya", "Theo Park"])
    }

    // MARK: the names offered

    @Test func savedVoicesComeFirstThenRecentNamesAndNothingTaken() {
        let saved = ["Maya Chen", "Theo"], recent = ["Maya", "Akshay", "theo", "Sam"]
        #expect(SpeakerNameSuggestions.names(saved: saved, recent: recent, matching: "") == ["Maya Chen", "Theo", "Maya", "Akshay"])
        #expect(SpeakerNameSuggestions.names(saved: saved, recent: recent, matching: "") .count == SpeakerNameSuggestions.limit)
        #expect(SpeakerNameSuggestions.names(saved: saved, recent: recent, taking: ["theo"], matching: "") == ["Maya Chen", "Maya", "Akshay", "Sam"])
        #expect(SpeakerNameSuggestions.names(saved: saved, recent: recent, matching: "ma") == ["Maya Chen", "Maya"])
        // A later word of a name matches too; what is typed in full is not offered back.
        #expect(SpeakerNameSuggestions.names(saved: saved, recent: recent, matching: "chen") == ["Maya Chen"])
        #expect(SpeakerNameSuggestions.names(saved: saved, recent: recent, matching: "Maya") == ["Maya Chen"])
        #expect(SpeakerNameSuggestions.names(saved: [], recent: [], matching: "x").isEmpty)
        #expect(SpeakerNameSuggestions.names(saved: [" "], recent: [""], matching: "").isEmpty)
    }

    @Test func recentNamesComeFromOtherNotesNewestFirst() {
        let library = NotesLibraryModel()
        let mine = UUID()
        func entry(_ id: UUID, _ names: [String]) -> NotesLibraryEntry {
            NotesLibraryEntry(id: id, title: "t", createdAt: Date(), updatedAt: Date(), speakerNames: names)
        }
        library.notes = [entry(mine, ["Own"]), entry(UUID(), ["Maya", "Theo"]), entry(UUID(), ["theo", "Sam"])]
        #expect(library.recentSpeakerNames(excluding: mine) == ["Maya", "Theo", "Sam"])
        #expect(library.recentSpeakerNames(excluding: mine, limit: 2) == ["Maya", "Theo"])
        #expect(library.recentSpeakerNames().first == "Own")
    }

    @Test func theLibraryKeepsEachNotesNamesAndAnOldIndexRebuildsThem() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-names-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesLibraryStore(directory: dir)
        var d = document()
        d.renameSpeaker(2, to: "Maya")
        try await store.write(NotesJournalRecord(document: d, elapsed: 12))
        #expect(try await store.list().first?.speakerNames == ["Maya"])
        // An index written before the field existed has no key for it: the index is rebuilt from the notes.
        let index = dir.appendingPathComponent("index.json")
        var old = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        old[0].removeValue(forKey: "speakerNames")
        try JSONSerialization.data(withJSONObject: old).write(to: index)
        #expect(try await NotesLibraryStore(directory: dir).list().first?.speakerNames == ["Maya"])
    }

    // MARK: what Done asks for

    @Test func onlyWhatChangedIsAsked() {
        let d = document()
        var draft = NameSpeakersDraft(d)
        #expect(draft.rows.map(\.id) == [1, 2, 3] && draft.namings(in: d).isEmpty)
        draft.rows[1].name = "  Maya "
        draft.rows[2].mergeInto = 1
        #expect(draft.namings(in: d) == [SpeakerNaming(person: 2, name: "Maya"), SpeakerNaming(person: 3, mergeInto: 1)])
        // A name that was there and is left alone is not a change; blank puts "Person N" back.
        var named = d
        named.renameSpeaker(2, to: "Maya")
        var again = NameSpeakersDraft(named)
        #expect(again.rows[1].name == "Maya" && again.namings(in: named).isEmpty)
        again.rows[1].name = " "
        #expect(again.namings(in: named) == [SpeakerNaming(person: 2, name: "")])
    }

    @Test func theReplaceCountIsEveryWholeWordPlaceOfTheRenamedOnes() {
        let d = document()
        var draft = NameSpeakersDraft(d)
        #expect(draft.replaceCount(in: d) == 0)
        draft.rows[1].name = "Maya"          // Person 2: two places ("Person 20" is not one)
        #expect(draft.replaceCount(in: d) == 2)
        draft.rows[2].name = "Theo"          // Person 3: two more
        #expect(draft.replaceCount(in: d) == 4)
        draft.rows[2].mergeInto = 1          // merged: nothing is replaced for it
        #expect(draft.replaceCount(in: d) == 2)
        draft.rows[1].name = "Person 2"      // the same name again: nothing changed
        #expect(draft.replaceCount(in: d) == 0)
    }

    @Test func theChipPreviewsWhatIsTypedOrThePlainName() {
        var d = document()
        d.renameSpeaker(2, to: "Maya")
        var draft = NameSpeakersDraft(d)
        #expect(draft.shown(draft.rows[1], in: d.roster) == "Maya" && draft.shown(draft.rows[0], in: d.roster) == "Person 1")
        draft.rows[1].name = ""
        #expect(draft.shown(draft.rows[1], in: d.roster) == "Person 2")
        draft.rows[0].name = " Theo "
        #expect(draft.shown(draft.rows[0], in: d.roster) == "Theo")
    }

    @Test func onlyThoseNamedNowWithEnoughSpeechAreRemembered() {
        var d = document()
        var draft = NameSpeakersDraft(d)
        var voices = SpeakerVoiceState(enabled: true)
        voices.canRemember = [1, 2]
        draft.rows[0].name = "Theo"
        draft.rows[1].name = "Maya"
        draft.rows[2].name = "Sam"          // not enough speech
        #expect(draft.remembered(in: d, voices: voices) == [1, 2])
        draft.rows[1].remember = false
        #expect(draft.remembered(in: d, voices: voices) == [1])
        voices.linked = [1: "Theo"]
        #expect(draft.remembered(in: d, voices: voices).isEmpty)
        voices.linked = [:]
        #expect(draft.remembered(in: d, voices: SpeakerVoiceState()).isEmpty)   // voices off: nothing is saved
        // Named before and left alone: not asked about again.
        d.renameSpeaker(1, to: "Theo")
        let before = NameSpeakersDraft(d)
        #expect(before.remembered(in: d, voices: voices).isEmpty)
    }

    // MARK: one edit through the session

    @Test func doneRenamesEveryoneAndReplacesTheirNamesAsOneUndo() throws {
        let h = harness()
        var draft = NameSpeakersDraft(h.document)
        draft.rows[1].name = "Maya"
        draft.rows[2].name = "Theo"
        h.model.onSpeakerEdit(.nameSpeakers(draft.namings(in: h.document), replaceInNotes: true))
        #expect(h.document.roster.displayName(2) == "Maya" && h.document.roster.displayName(3) == "Theo")
        #expect(h.document.text == "## Plan\n- [ ] **Maya** sends the spec\n- Theo books the review\n- Person 20 joins\n- Maya agreed with Theo.")
        #expect(h.text == h.document.text)
        #expect(h.model.visibleSpeakerBanner?.text == "Updated 2 speakers and replaced their names in the notes (4 places).")
        #expect(h.model.speakerBannerUndoable)
        // The banner's Undo puts both back; the names stay (they are the transcript's).
        h.model.onSpeakerEdit(.undo)
        #expect(h.document.text == Self.notes && h.text == Self.notes && h.model.visibleSpeakerBanner == nil)
        #expect(h.document.roster.displayName(2) == "Maya")
    }

    @Test func withTheToggleOffOnlyTheNamesChange() {
        let h = harness()
        var draft = NameSpeakersDraft(h.document)
        draft.rows[0].name = "Sam"
        h.model.onSpeakerEdit(.nameSpeakers(draft.namings(in: h.document), replaceInNotes: false))
        #expect(h.document.roster.displayName(1) == "Sam" && h.document.text == Self.notes)
        #expect(h.model.visibleSpeakerBanner?.text == "Updated 1 speaker.")
        #expect(!h.model.speakerBannerUndoable)
        h.model.onSpeakerEdit(.nameSpeakers([], replaceInNotes: true))
        #expect(h.model.visibleSpeakerBanner == nil)
    }

    @Test func samePersonMergesAndASecondEditCannotUndoAnOlderReplace() {
        let h = harness()
        var draft = NameSpeakersDraft(h.document)
        draft.rows[1].name = "Maya"
        draft.rows[2].mergeInto = 2
        h.model.onSpeakerEdit(.nameSpeakers(draft.namings(in: h.document), replaceInNotes: true))
        #expect(h.document.roster.resolve(3) == 2 && h.document.speakerCount == 2)
        #expect(h.document.roster.displayName(3) == "Maya" && h.document.text.contains("**Maya** sends"))
        // Typing in the notes since: Undo no longer applies.
        h.editor.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(!h.model.speakerBannerUndoable)
    }

    // MARK: the line after Stop

    @Test func theLineShowsAfterStopUntilEveryoneIsNamedOrItIsDismissed() {
        let h = harness()
        #expect(h.model.showsNameSpeakersLine)
        h.model.state = .recording
        #expect(!h.model.showsNameSpeakersLine)
        h.model.state = .paused
        #expect(!h.model.showsNameSpeakersLine)
        h.model.state = .stopped
        h.model.onSpeakerEdit(.rename(1, to: "A"))
        h.model.onSpeakerEdit(.rename(2, to: "B"))
        #expect(h.model.showsNameSpeakersLine)
        h.model.onSpeakerEdit(.rename(3, to: "C"))
        #expect(!h.model.showsNameSpeakersLine)
        h.model.onSpeakerEdit(.rename(3, to: ""))
        #expect(h.model.showsNameSpeakersLine)
        h.model.nameLineDismissed.insert(h.document.id)
        #expect(!h.model.showsNameSpeakersLine)
        // A note without speaker labels never shows it.
        let plain = NotesModel()
        plain.document = NotesDocument(text: "hello")
        plain.state = .stopped
        #expect(!plain.showsNameSpeakersLine)
    }

    @Test func theSheetOpensOverThePeopleAndClosingWithoutDoneLeavesTheLine() throws {
        let h = harness()
        #expect(!h.model.namingSpeakers)
        h.model.beginNamingSpeakers()
        let state = try #require(h.model.nameSpeakers)
        #expect(state.draft.rows.map(\.id) == [1, 2, 3] && state.suggesting == 1)
        state.draft.rows[0].name = "Sam"
        #expect(NameSpeakersState(h.document, draft: state.draft).suggesting == 2)
        h.model.endNamingSpeakers()
        #expect(!h.model.namingSpeakers && h.model.showsNameSpeakersLine)
    }

    // MARK: ▶ sample

    @Test func aPersonsSampleIsTheirFirstTurnWithTheAudioTheNoteKept() throws {
        let h = harness()
        #expect(try #require(h.model.speakerSample(2)).text == "OK.")
        #expect(try #require(h.model.speakerSample(2)).audio.isEmpty)
        h.model.keptAudio = [0: URL(fileURLWithPath: "/dev/null/0.m4a"), 1: URL(fileURLWithPath: "/dev/null/1.m4a")]
        let sample = try #require(h.model.speakerSample(3))
        #expect(sample.text == "Budget is fine." && sample.audio.map(\.segment) == [1])
        #expect(h.model.speakerSample(9) == nil)
    }

    @Test func aLongTurnIsCutOnAWordBoundary() {
        #expect(NotesModel.sampleText("  Short   one. ") == "Short one.")
        let long = "Okay, so we're kicking off the Lantern project today, and the launch target moved to March third."
        let cut = NotesModel.sampleText(long, limit: 40)
        #expect(cut == "Okay, so we're kicking off the Lantern…" && cut.count <= 41)
        #expect(NotesModel.sampleText("aaaa bbbb cccc", limit: 9) == "aaaa bbbb…")
    }
}
