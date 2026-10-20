import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Review regressions for feat/notes-edit (issue #17): editor.
@MainActor
@Suite struct NotesReviewRegressionTests {
    /// Spec rule 2: AI changes are held while marked text exists. A reorganize is never held (and its `version` check
    /// cannot see an uncommitted composition), so it replays mid-composition: NSTextView drops the composition and
    /// the caret lands at the end of the document, where the next keystroke claims the AI tail.
    @Test func aReorganizeDuringIMECompositionKeepsTheCompositionAndCaret() throws {
        let h = NotesEditorTests.Harness(typed: "## Budget\n- keep the vendor contract\n\n## Hiring\n- no new headcount\n\n## Budget\n- review in May\n")
        let tv = h.editor.textView
        let at = (h.text as NSString).range(of: "no new").location
        tv.setSelectedRange(NSRange(location: at, length: 0))
        tv.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: at, length: 0))
        try #require(tv.hasMarkedText())
        try #require(h.reorganize("## Budget\n- keep the vendor contract\n- review in May\n\n## Hiring\n- no new headcount") != nil)
        #expect(tv.hasMarkedText())                                  // fails: the composition is gone
        #expect(tv.selectedRange().location < h.text.utf16.count)    // fails: caret at the very end
    }

    /// The same for an append replayed while composing (the Stop path applies a held append and `freezeAll`, and
    /// `schedule()` can publish `freezeOverflow()`, whatever the composing state).
    @Test func anAppendDuringIMECompositionKeepsTheComposition() throws {
        let h = NotesEditorTests.Harness(typed: "my own line\n", segments: ["a"])
        let tv = h.editor.textView
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 2, length: 0))
        try #require(tv.hasMarkedText())
        try #require(h.append("- a") != nil)
        #expect(tv.hasMarkedText())                                  // fails: the composition is gone
    }

    /// The common "type my own notes at the bottom while recording" flow: an append lands after the caret (which
    /// correctly stays put, at `tailStart`), and the user's very next keystroke, on their own line, is an insertion
    /// at `tailStart` with a non-empty tail, so it claims the whole AI tail. The AI never gets to grow its block.
    @Test func typingOnOnesOwnLastLineDoesNotClaimTheAITail() throws {
        let h = NotesEditorTests.Harness(typed: "my own line", segments: ["a"])
        h.editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
        try #require(h.append("## Plan\n- a") != nil)
        #expect(h.editor.textView.selectedRange() == NSRange(location: 11, length: 0))
        h.type("!")                                                  // "my own line!"
        #expect(h.text.hasPrefix("my own line!\n\n## Plan"))
        #expect(!h.model.document.tail.isEmpty)                      // fails: tail claimed
    }
}

import SwiftUI

@MainActor
@Suite struct NotesReviewTabSwitchTests {
    /// Notes → Split builds a new editor while the old one is dismantled. If the new coordinator is made first, the old
    /// one's `detach()` clears the sink the new one just installed, and every later AI change is dropped (and only a
    /// full `load()` resync on the next SwiftUI update brings it back: caret, scroll and undo reset).
    @Test func switchingNotesToSplitKeepsTheEditorSink() async throws {
        let model = NotesModel()
        let host = NSHostingView(rootView: NotesView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.onPendingChanges != nil)
        model.tab = .split
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        func editors(_ v: NSView) -> [NotesTextView] { (v as? NotesTextView).map { [$0] } ?? v.subviews.flatMap(editors) }
        let live = editors(host)
        #expect(live.count == 1)                                     // the Split pane's editor is on screen
        #expect(model.onPendingChanges != nil)                       // fails: its sink was cleared by the old detach()
        // An AI change now is dropped instead of replayed; the on-screen storage falls behind the model.
        var d = model.document
        d.userEdit(NSRange(location: 0, length: 0), "typed")
        model.document = d
        model.tab = .notes
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        #expect(model.onPendingChanges != nil)
    }
}
