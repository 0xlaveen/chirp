import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Edit by Voice (#97) end to end through `NotesHarness`: what is said between the two presses goes to its own socket
/// and never into the transcript, the edit runs in the pass slot and applies as one undo step only to unchanged notes.
@MainActor
@Suite(.serialized) struct NotesVoiceEditTests {
    static let health = Health(correction: "available", notesStructure: true, notesCorrection: true, notesReorganize: true,
                               notesEdit: true)
    static let notes = "## Plan\n- keep the vendor\n- drop me"
    static let edited = "## Plan\n- keep the vendor"
    nonisolated static let instruction = "remove the last bullet"

    /// A harness whose socket `command` answers with the instruction (the others with "Segment n.").
    private func harness(command: Int, health: Health? = health) -> NotesHarness {
        let instruction = Self.instruction
        return NotesHarness(health: health, finalText: { $0 == command ? instruction : "Segment \($0)." })
    }

    /// Edit, `seconds` of speech, Done; with `wait` until the edit ended.
    private func say(_ h: NotesHarness, seconds: Double = 2, wait: Bool = true) async {
        h.session.toggleVoiceEdit()
        await h.settle()
        await h.until("listening") { h.model.voiceEdit.isListening }
        await h.speak(seconds)
        h.session.toggleVoiceEdit()
        guard wait else { return }
        await h.until("edit done") { if case .done = h.model.voiceEdit { true } else { false } }
    }

    private func typeNotes(_ h: NotesHarness) async {
        await h.typeAtEnd(Self.notes)
        #expect(h.document.text == Self.notes)
    }

    // MARK: routing

    @Test func whileRecordingTheCommandGoesToItsOwnSocketAndNeverIntoTheTranscript() async {
        let h = harness(command: 1)
        h.http.answerEdit(.ok(Self.edited))
        await typeNotes(h)
        await h.record()
        await h.speak(3)
        let before = h.streams.bytesBySocket[0] ?? 0
        await say(h)
        #expect(h.streams.started == 3)                                  // notes, command, notes again
        #expect((h.streams.bytesBySocket[1] ?? 0) > 0)
        #expect((h.streams.bytesBySocket[0] ?? 0) - before < 3200)       // the notes socket stopped at the press
        // The segment before the command was structured first: the edit sees the newest notes.
        #expect(h.http.editRequests == [.init(notes: Self.notes + "\n\n## Notes\n- Segment 0.", instruction: Self.instruction)])
        await h.speak(3)
        #expect((h.streams.bytesBySocket[2] ?? 0) > 0)                   // back to the notes after the second press
        await h.stop()
        #expect(h.transcript == ["Segment 0.", "Segment 2."])
        #expect(!h.document.segments.contains { $0.text.contains("remove") })
        #expect(h.text.hasPrefix(Self.edited) && !h.text.contains("drop me"))
        h.expectEditorInSync()
    }

    @Test func outsideARecordingTheMicrophoneOpensJustForTheCommand() async {
        let h = harness(command: 0)
        h.http.answerEdit(.ok(Self.edited))
        await typeNotes(h)
        h.session.toggleVoiceEdit()
        await h.until("listening") { h.model.voiceEdit.isListening && h.engine.isTapped }
        #expect(h.recorder.state == .idle && h.model.statusText == NotesStatus.voiceEditListening)
        await h.speak(2)
        h.session.toggleVoiceEdit()
        await h.until("applied") { h.model.showEditedChip }
        #expect(!h.session.isCapturing && h.document.segments.isEmpty)
        #expect(h.text == Self.edited && h.document.text == Self.edited)
        #expect(h.edges.announcements.last == NotesStatus.voiceEdited)
    }

    // MARK: apply, undo, conflict

    @Test func anAppliedEditIsOneUndoStepAndTheChipUndoesIt() async {
        let h = harness(command: 0)
        h.http.answerEdit(.ok(Self.edited), .ok(Self.edited))
        await typeNotes(h)
        await say(h)
        #expect(h.text == Self.edited && h.model.showEditedChip)
        #expect(h.editor.textView.undoManager?.undoActionName == "Edit by Voice")
        await h.undo()
        #expect(h.text == Self.notes && h.document.text == Self.notes)
        await h.redo()
        #expect(h.text == Self.edited)
        h.model.undoEdit()
        await h.settle()
        #expect(h.text == Self.notes && h.document.text == Self.notes)
        h.expectEditorInSync()
    }

    @Test func typingWhileTheEditRunsKeepsTheNotesAndSaysSo() async {
        let h = harness(command: 0)
        h.http.answerEdit(.ok(Self.edited))
        h.http.hold = true
        await typeNotes(h)
        await say(h, wait: false)
        await h.until("edit sent") { h.http.waiting == 1 }
        #expect(h.model.statusText == NotesStatus.voiceEditRunning)
        await h.typeAtEnd("\n- typed meanwhile")
        h.http.release()
        await h.until("done") { h.model.voiceEdit != .editing(instruction: Self.instruction) && h.model.voiceEditNote != nil }
        #expect(h.text == Self.notes + "\n- typed meanwhile")
        #expect(h.model.voiceEditNote == "Notes changed while editing — try again" && !h.model.showEditedChip)
    }

    @Test func appendsWaitForARunningEdit() async {
        let h = harness(command: 1)
        h.http.answerEdit(.ok(Self.edited))
        await typeNotes(h)
        await h.record()
        await h.speak(3)
        h.http.hold = true
        await say(h, wait: false)
        await h.until("edit sent") { h.http.waiting == 1 }
        let structures = h.http.structureRequests.count
        await h.speak(13).pause(1)
        await h.until("segment committed") { h.document.segments.count == 2 }
        #expect(h.http.structureRequests.count == structures)           // the slot is the edit's
        h.http.release()
        await h.until("applied") { h.model.showEditedChip }
        await h.stop()
        #expect(h.text.hasPrefix(Self.edited) && !h.text.contains("drop me"))
        #expect(h.http.structureRequests.count > structures)
    }

    // MARK: refusals, failures, cancel

    @Test func aRefusalLeavesTheNotesAndExplains() async {
        let h = harness(command: 0)
        h.http.answerEdit(.refused("adds_content"))
        await typeNotes(h)
        await say(h)
        #expect(h.text == Self.notes)
        #expect(h.model.voiceEditNote == NotesStatus.voiceEditNote(.refused("adds_content")))
        #expect(h.edges.announcements.last == NotesStatus.voiceEditNote(.refused("adds_content")))
    }

    @Test func aRejectedEditShowsTheGuard() async {
        let h = harness(command: 0)
        h.http.answerEdit(.rejected("dropped_unasked"))
        await typeNotes(h)
        await say(h)
        #expect(h.text == Self.notes && h.model.voiceEditNote == "Couldn’t edit notes (rejected: dropped_unasked)")
    }

    @Test func aPreemptedEditRunsAgain() async {
        let h = harness(command: 0)
        h.http.answerEdit(.preempted, .ok(Self.edited))
        await typeNotes(h)
        await say(h)
        #expect(h.http.editRequests.count == 2 && h.text == Self.edited)
    }

    @Test func escDropsTheCommandAndRecordingGoesOn() async {
        let h = harness(command: 1)
        await typeNotes(h)
        await h.record()
        await h.speak(3)
        h.session.toggleVoiceEdit()
        await h.until("listening") { h.model.voiceEdit.isListening }
        await h.speak(1)
        h.model.onVoiceEditCancel()
        await h.until("back to notes") { h.model.voiceEdit == .idle && h.streams.started == 3 }
        await h.speak(3)
        await h.stop()
        #expect(h.http.editRequests.isEmpty && h.text.hasPrefix(Self.notes))
        #expect(h.transcript == ["Segment 0.", "Segment 2."])
    }

    @Test func nothingHeardSaysSo() async {
        let h = NotesHarness(health: Self.health, finalText: { _ in "" })
        await typeNotes(h)
        await say(h)
        #expect(h.http.editRequests.isEmpty && h.model.voiceEditNote == "Didn’t catch an edit — try again")
    }

    @Test func aSelectionLimitsTheEditToItsLines() async {
        let h = harness(command: 0)
        let text = "## Intro\n- hello\n## Plan\n- keep the vendor\n- drop me"
        h.http.answerEdit(.ok("## Plan\n- keep the vendor"))
        await h.typeAtEnd(text)
        let plan = (text as NSString).range(of: "Plan\n- keep the vendor\n- drop")
        h.editor.textView.setSelectedRange(plan)
        await say(h)
        #expect(h.http.editRequests.first?.notes == "## Plan\n- keep the vendor\n- drop me")
        #expect(h.text == "## Intro\n- hello\n## Plan\n- keep the vendor")
    }

    @Test func aServerWithoutTheEndpointHidesTheButton() async {
        let h = NotesHarness()
        #expect(!h.model.voiceEditAvailable && !h.model.canVoiceEdit)
        h.session.toggleVoiceEdit()
        await h.settle()
        #expect(h.model.voiceEdit == .idle && h.streams.attempts == 0)
    }

    @Test func recordWaitsWhileACommandHasTheMicrophone() async {
        let h = harness(command: 0)
        await typeNotes(h)
        h.session.toggleVoiceEdit()
        await h.until("listening") { h.model.voiceEdit.isListening }
        h.session.toggle(fromHotkey: false)
        await h.settle()
        #expect(h.recorder.state == .idle && h.edges.beeps == 1)
        h.model.onVoiceEditCancel()
        await h.until("idle") { h.model.voiceEdit == .idle && !h.session.isCapturing }
    }
}

/// The document side of a voice edit: its scope, the request and the conflict-safe apply.
@Suite struct NotesEditDocumentTests {
    private func doc(_ text: String) -> NotesDocument {
        var d = NotesDocument()
        d.userEdit(NSRange(location: 0, length: 0), text)
        return d
    }

    @Test func scopeIsTheSelectedLinesTheWholeNotesOrTheTrailingSections() {
        let d = doc("## A\n- one\n## B\n- two\n- three\n")
        #expect(d.editScope(selection: nil) == .range(NSRange(location: 0, length: d.text.utf16.count)))
        let inB = (d.text as NSString).range(of: "two")
        #expect(d.editScope(selection: inB) == .range((d.text as NSString).range(of: "- two\n")))
        #expect(doc("  \n").editScope(selection: nil) == .nothing("empty"))
        let long = doc((0..<60).map { "## Section \($0)\n- " + String(repeating: "word ", count: 12) }.joined(separator: "\n"))
        guard case .range(let tail) = long.editScope(selection: nil) else { Issue.record("no scope"); return }
        #expect(NSMaxRange(tail) == long.text.utf16.count && tail.location > 0 && tail.length <= NotesDocument.maxReorganizeChars)
        #expect(long.editScope(selection: NSRange(location: 0, length: long.text.utf16.count)) == .nothing("too_long"))
    }

    @Test func applyReplacesTheScopeKeepingItsFrameAndIsAUserEdit() {
        var d = doc("## A\n- one\n\n## B\n- two\n- three\n\n")
        let range = (d.text as NSString).range(of: "## B\n- two\n- three\n\n")
        let request = d.editRequest("remove three", range: range)
        #expect(request.notes == "## B\n- two\n- three")
        let change = d.applyEdit(NotesEditResponse(markdown: "## B\n- two", edited: true), for: request)
        #expect(change?.kind == .edit)
        #expect(d.text == "## A\n- one\n\n## B\n- two\n\n")
        #expect(d.tailStart == d.count)
    }

    @Test func applyRefusesChangedOrOtherNotes() {
        var d = doc("## A\n- one")
        let request = d.editRequest("x", range: NSRange(location: 0, length: d.text.utf16.count))
        let answer = NotesEditResponse(markdown: "## A", edited: true)
        var typed = d
        typed.userEdit(NSRange(location: typed.text.utf16.count, length: 0), "!")
        #expect(typed.applyEdit(answer, for: request) == nil && typed.text == "## A\n- one!")
        var other = doc("## A\n- one")
        #expect(other.applyEdit(answer, for: request) == nil)
        #expect(d.applyEdit(NotesEditResponse(markdown: "## A\n- one", edited: true, changed: false), for: request) == nil)
        #expect(d.applyEdit(answer, for: request) != nil && d.text == "## A")
    }

    @Test func responsesDecodeAndRefusalsAreCodes() throws {
        func decode(_ json: String) throws -> NotesEditResponse {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(NotesEditResponse.self, from: Data(json.utf8))
        }
        let ok = try decode(###"{"markdown":"## A","edited":true,"changed":true,"error":null,"timings_ms":{"edit":12.5}}"###)
        #expect(ok.edited && ok.changed && ok.refusal == nil)
        let refused = try decode(#"{"markdown":null,"edited":false,"changed":false,"error":"refused","reason":"adds_content"}"#)
        #expect(refused.refusal == "adds_content")
        let odd = try decode(#"{"markdown":null,"edited":false,"error":"refused","reason":"Free text here"}"#)
        #expect(odd.refusal == "unclear" && odd.failureLabel == "refused")
        #expect(try decode(#"{"markdown":null,"edited":false,"error":"preempted"}"#).preempted)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            NotesEditRequest(notes: "n", instruction: "i", range: NSRange(location: 3, length: 1), documentID: UUID()))) as? [String: String]
        #expect(body == ["notes": "n", "instruction": "i"])
    }
}
