import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// The editor's coordinator over a real (offscreen) NSTextView, wired to a model whose `onUserEdit` applies edits the
/// way the recorder does.
@MainActor
@Suite struct NotesEditorTests {
    @MainActor final class Harness {
        let model = NotesModel()
        let editor: NotesEditorCoordinator
        var reported: [(NSRange, String, NotesTextChange.Kind)] = []
        var focus: [(Bool, Bool)] = []

        init(typed: String = "", segments: [String] = []) {
            var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
            if !typed.isEmpty { d.userEdit(NSRange(location: 0, length: 0), typed) }
            for (i, t) in segments.enumerated() { d.append(NotesSegment(id: i, offset: 0, raw: t)) }
            model.document = d
            editor = NotesEditorCoordinator(model: model)
            editor.isFocused = { true }
            model.onUserEdit = { [unowned self] range, text, kind in
                reported.append((range, text, kind))
                model.document.userEdit(range, text, kind: kind)
            }
            model.onEditorFocus = { [unowned self] inTail, composing in focus.append((inTail, composing)) }
        }

        var text: String { editor.textView.string }

        /// An AI append, as the recorder publishes it.
        @discardableResult
        func append(_ markdown: String) -> NotesTextChange? {
            var d = model.document
            guard let r = d.nextStructureRequest(), let change = d.apply(NotesStructureResponse(markdown: markdown, structured: true), for: r)
            else { return nil }
            model.document = d
            model.enqueue([change])
            return change
        }

        func reorganize(_ markdown: String) -> NotesTextChange? {
            var d = model.document
            guard let r = d.reorganizeRequest(final: false, manual: true),
                  let change = d.applyReorganize(NotesReorganizeResponse(markdown: markdown, reorganized: true), for: r) else { return nil }
            model.document = d
            model.enqueue([change])
            return change
        }

        func type(_ s: String, at location: Int? = nil) {
            let range = location.map { NSRange(location: $0, length: 0) } ?? editor.textView.selectedRange()
            editor.textView.insertText(s, replacementRange: range)
        }
    }

    @Test func theEditorIsConfiguredForPrivacyAndPlainText() {
        let probe = NotesEditorProbe(Harness().editor.textView)
        #expect(!probe.isRichText && !probe.importsGraphics && probe.allowsUndo && probe.usesFindBar)
        #expect(!probe.quoteSubstitution && !probe.dashSubstitution && !probe.textReplacement)
        #expect(!probe.linkDetection && !probe.dataDetection && !probe.smartInsertDelete)
        #expect(probe.continuousSpellChecking && !probe.spellingCorrection && !probe.textCompletion)
        #expect(probe.writingToolsOff && probe.pasteTypes == [.string])
    }

    @Test func anAppliedAppendMatchesTheModelAndUndoesInOneStep() throws {
        let h = Harness(typed: "## Mine\n- typed\n", segments: ["we ship friday"])
        #expect(h.text == h.model.document.text)
        try #require(h.append("## Plan\n- Ship **Friday**\n- [ ] Tell Maya") != nil)
        #expect(h.text == h.model.document.text && h.text.hasSuffix("- [ ] Tell Maya"))
        #expect(h.reported.isEmpty)                                       // a replayed change is not a user edit
        #expect(h.editor.undo.undoActionName == NotesEditorCoordinator.updateAction)
        h.editor.undo.undo()
        #expect(h.text == "## Mine\n- typed\n")
        // Undo reached the model as a user edit (it reverts text in the tail, so the tail is the user's now).
        #expect(h.model.document.text == h.text && h.reported.count == 1 && h.model.document.tail.isEmpty)
    }

    @Test func aReorganizeIsOneUndoStepNamedForTheChip() throws {
        let h = Harness(typed: "## Budget\n- keep the vendor contract\n\n## Hiring\n- no new headcount\n\n## Budget\n- review in May\n")
        try #require(h.reorganize("## Budget\n- keep the vendor contract\n- review in May\n\n## Hiring\n- no new headcount") != nil)
        #expect(h.text == h.model.document.text)
        #expect(h.editor.undo.undoActionName == NotesEditorCoordinator.reorganizeAction)
        h.editor.undoReorganize()
        #expect(h.text.hasSuffix("## Budget\n- review in May\n") && h.model.document.text == h.text)
        // Once something else is on top, the chip's Undo does nothing.
        try #require(h.reorganize("## Budget\n- keep the vendor contract\n- review in May\n\n## Hiring\n- no new headcount") != nil)
        h.type("x", at: 0)
        h.editor.textView.breakUndoCoalescing()
        let before = h.text
        h.editor.undoReorganize()
        #expect(h.text == before)
    }

    @Test func theCaretBeforeTheTailStaysPut() throws {
        let h = Harness(typed: "my own line\n", segments: ["a"])
        h.editor.textView.setSelectedRange(NSRange(location: 3, length: 4))
        try #require(h.append("- a") != nil)
        #expect(h.editor.textView.selectedRange() == NSRange(location: 3, length: 4))
        // A caret at the very end stays before what was appended.
        let h2 = Harness(typed: "end", segments: ["a"])
        h2.editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        try #require(h2.append("- a") != nil)
        #expect(h2.editor.textView.selectedRange() == NSRange(location: 3, length: 0) && h2.text == "end\n\n- a")
    }

    @Test func theCaretFollowsItsLineThroughAReorganize() throws {
        let h = Harness(typed: "## Notes\n- alpha point here, with words\n- beta point here, with words\n\n## Notes\n- gamma point here\n")
        let ns = h.text as NSString
        let gamma = ns.range(of: "- gamma point here").location
        h.editor.textView.setSelectedRange(NSRange(location: gamma + 4, length: 0))
        try #require(h.reorganize("## Notes\n- gamma point here\n- alpha point here, with words\n- beta point here, with words") != nil)
        let moved = (h.text as NSString).range(of: "- gamma point here").location
        #expect(h.editor.textView.selectedRange() == NSRange(location: moved + 4, length: 0))
        // A line that is gone puts the caret at the start of the scope.
        h.editor.textView.setSelectedRange(NSRange(location: 12, length: 0))
        let line = (h.text as NSString).lineRange(for: NSRange(location: 12, length: 0))
        #expect((h.text as NSString).substring(with: line).hasPrefix("- gamma"))
        try #require(h.reorganize("## Notes\n- alpha point here, with words\n- beta point here, with words\n- gamma point, merged") != nil)
        #expect(h.editor.textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func typingIsReportedOnceAndReplaysAreNot() throws {
        let h = Harness(typed: "abc", segments: ["a"])
        h.type("X", at: 1)
        #expect(h.reported.count == 1 && h.reported[0].0 == NSRange(location: 1, length: 0) && h.reported[0].1 == "X")
        #expect(h.model.document.text == "aXbc" && h.text == "aXbc")
        try #require(h.append("- a") != nil)
        #expect(h.reported.count == 1 && h.text == h.model.document.text)
        // Typing inside the tail claims it: the tint goes away.
        #expect(h.editor.textView.tint.length > 0)
        h.type("!", at: h.text.utf16.count)
        #expect(h.model.document.tail.isEmpty && h.editor.textView.tint.length == 0)
    }

    @Test func theCaretInTheTailIsReported() throws {
        let h = Harness(typed: "mine\n", segments: ["a"])
        try #require(h.append("- a") != nil)
        h.editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(h.focus.last.map { !$0.0 } ?? true)
        h.editor.textView.setSelectedRange(NSRange(location: h.text.utf16.count - 1, length: 0))
        #expect(h.focus.last?.0 == true)
        h.editor.isFocused = { false }
        h.editor.reportFocus()
        #expect(h.focus.last?.0 == false)
    }

    @Test func returnContinuesListsAndTabIndents() {
        let h = Harness(typed: "- one")
        h.editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(h.editor.continueList())
        #expect(h.text == "- one\n- " && h.model.document.text == h.text)
        #expect(h.editor.indent(by: 1))
        #expect(h.text == "- one\n  - " && h.editor.textView.selectedRange().location == 10)
        #expect(h.editor.indent(by: -1))
        #expect(h.text == "- one\n- ")
        // Return on an empty item removes the marker.
        #expect(h.editor.continueList())
        #expect(h.text == "- one\n")
        let task = Harness(typed: "- [x] done")
        task.editor.textView.setSelectedRange(NSRange(location: 10, length: 0))
        #expect(task.editor.continueList())
        #expect(task.text == "- [x] done\n- [ ] ")
        let plain = Harness(typed: "just text")
        plain.editor.textView.setSelectedRange(NSRange(location: 9, length: 0))
        #expect(!plain.editor.continueList() && !plain.editor.indent(by: 1))
    }

    @Test func clickingABoxTogglesItAsOneStep() {
        let h = Harness(typed: "- [ ] call Theo")
        #expect(h.editor.toggleTask(at: 3))
        #expect(h.text == "- [x] call Theo" && h.model.document.text == h.text)
        #expect(h.reported.last?.2 == .toggleTask && h.editor.undo.undoActionName == NotesEditorCoordinator.toggleAction)
        #expect(!h.editor.toggleTask(at: 9))
        h.editor.undo.undo()
        #expect(h.text == "- [ ] call Theo" && h.model.document.text == h.text)
    }

    @Test func boldAndItalicWrapTheSelection() {
        let h = Harness(typed: "ship friday")
        h.editor.textView.setSelectedRange(NSRange(location: 5, length: 6))
        h.editor.wrapSelection("**")
        #expect(h.text == "ship **friday**" && h.editor.textView.selectedRange() == NSRange(location: 7, length: 6))
        h.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        h.editor.wrapSelection("_")
        #expect(h.text == "__ship **friday**" && h.editor.textView.selectedRange() == NSRange(location: 1, length: 0))
        #expect(h.model.document.text == h.text)
    }

    @Test func aReplacedDocumentReloadsAndClearsUndo() throws {
        let h = Harness(typed: "old notes", segments: ["a"])
        try #require(h.append("- a") != nil)
        #expect(h.editor.undo.canUndo)
        h.model.document = NotesDocument()
        h.editor.update()
        #expect(h.text.isEmpty && !h.editor.undo.canUndo)
    }

    @Test func stylingMarksHeadingsAndKeepsTheCharacters() throws {
        let h = Harness(typed: "## Budget\n- **Decision:** keep it\n- [x] done\n")
        let storage = try #require(h.editor.textView.textStorage)
        #expect(storage.string == "## Budget\n- **Decision:** keep it\n- [x] done\n")
        let heading = try #require(storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        #expect(heading.pointSize == 17)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .tertiaryLabelColor)
        #expect(storage.attribute(.foregroundColor, at: 14, effectiveRange: nil) as? NSColor == .systemGreen)
        let done = (storage.string as NSString).range(of: "done").location
        #expect(storage.attribute(.strikethroughStyle, at: done, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test func restylingTenThousandCharsIsQuick() {
        let line = "- **Decision:** keep the _vendor_ contract and more words here\n## Heading\n"
        let h = Harness(typed: String(repeating: line, count: 10_000 / line.count + 1))
        let storage = h.editor.textView.textStorage!
        let elapsed = ContinuousClock().measure { NotesEditorStyle.restyle(storage) }
        // Debug builds are slower than the app; this guards against an accidental quadratic restyle.
        #expect(elapsed < .milliseconds(200), "restyle took \(elapsed)")
    }
}
