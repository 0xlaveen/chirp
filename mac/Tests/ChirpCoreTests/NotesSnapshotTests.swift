import Foundation
import Testing
@testable import ChirpCore

@Suite struct NotesSnapshotTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func change(_ old: String, _ new: String, _ kind: NotesTextChange.Kind = .reorganize, run: Int? = nil) -> NotesTextChange {
        var c = NotesDocument.diff(old, new, kind: kind)!
        c.run = run
        return c
    }

    private func store(_ texts: [String], at: Date? = nil) -> NotesSnapshots {
        var s = NotesSnapshots()
        for (a, b) in zip(texts, texts.dropFirst()) { s.record([change(a, b)], from: a, result: b, at: at ?? t0) }
        return s
    }

    @Test func eachAppliedReorganizeKeepsTheTextBeforeIt() {
        let s = store(["a b c", "c b a"])
        #expect(s.items.count == 1 && s.latest?.before == "a b c" && s.latest?.after == "c b a" && s.latest?.at == t0)
    }

    @Test func appendsAreNotSnapshotted() {
        var s = NotesSnapshots()
        s.record([change("a", "a b", .append)], from: "a", result: "a b", at: t0)
        #expect(s.items.isEmpty)
    }

    @Test func atMostFiveAreKeptNewestLast() {
        let texts = (0...8).map { "text \($0)" }
        let s = store(texts)
        #expect(s.items.count == NotesSnapshots.limit)
        #expect(s.items.map(\.before) == ["text 3", "text 4", "text 5", "text 6", "text 7"])
        var cleared = s
        cleared.removeAll()
        #expect(cleared.items.isEmpty)
    }

    @Test func theStepsOfOneOrganizeRunAreOneSnapshot() {
        var s = NotesSnapshots()
        s.record([change("one two three", "ONE two three", run: 7)], from: "one two three", result: "ONE two three", at: t0)
        s.record([change("ONE two three", "ONE two THREE", run: 7)], from: "ONE two three", result: "ONE two THREE", at: t0)
        #expect(s.items.count == 1 && s.latest?.before == "one two three" && s.latest?.after == "ONE two THREE")
        s.record([change("ONE two THREE", "x", run: 8)], from: "ONE two THREE", result: "x", at: t0)
        #expect(s.items.count == 2)
    }

    @Test func aReplayThatMissesTheResultKeepsNothing() {
        var s = NotesSnapshots()
        s.record([change("a", "b")], from: "a", result: "something typed meanwhile", at: t0)
        #expect(s.items.isEmpty)
    }

    @Test func restoreIsTheEarlierTextWhenNothingChangedSince() {
        let s = store(["## A\n- x\n\n## B\n- y", "## B\n- y\n\n## A\n- x"])
        #expect(NotesSnapshots.restore(s.latest!, now: "## B\n- y\n\n## A\n- x") == .text("## A\n- x\n\n## B\n- y"))
    }

    @Test func laterTypingAfterTheReorganizedStretchIsKept() {
        let before = "intro\nalpha beta\ngamma delta\nend"
        let after = "intro\ngamma delta\nalpha beta\nend"
        let s = store([before, after])
        let typed = after + "\nmy own line"
        #expect(NotesSnapshots.restore(s.latest!, now: typed) == .text(before + "\nmy own line"))
        let typedFirst = "my title\n" + after
        #expect(NotesSnapshots.restore(s.latest!, now: typedFirst) == .text("my title\n" + before))
    }

    @Test func laterTypingInsideTheReorganizedStretchNeedsAConfirmation() {
        let before = "intro\nalpha beta\ngamma delta\nend"
        let after = "intro\ngamma delta\nalpha beta\nend"
        let s = store([before, after])
        #expect(NotesSnapshots.restore(s.latest!, now: after.replacingOccurrences(of: "gamma", with: "GAMMA")) == .replace(before))
    }

    @Test func theDiffShowsRemovedAndAddedWordsWithShortContext() throws {
        let long = (1...30).map { "w\($0)" }.joined(separator: " ")
        let s = store([long + " cat sat", long + " dog sat"])
        let segments = try #require(NotesSnapshots.diff(s.latest!))
        #expect(segments.contains(WordDiff.Segment(.removed, "cat")) && segments.contains(WordDiff.Segment(.added, "dog")))
        #expect(segments.first?.text.hasPrefix("… ") == true && !segments.contains { $0.text.contains("w1 ") })
    }
}
