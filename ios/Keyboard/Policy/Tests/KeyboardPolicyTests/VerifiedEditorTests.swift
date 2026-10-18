import Foundation
import Testing
@testable import KeyboardPolicy

@MainActor
private final class FakeProxy {
    var cursor = CursorContext(documentID: UUID(), before: "user: ", after: " suffix")
    var deletes = 0
    var inserts = 0
    var afterDelete: ((FakeProxy) -> Void)?

    func delete() {
        deletes += 1
        cursor.before?.removeLast()
        afterDelete?(self)
    }
    func insert(_ text: String) { inserts += 1; cursor.before = (cursor.before ?? "") + text }
    func apply(_ plan: EditPlan) -> Bool {
        VerifiedEditor.apply(plan, context: { self.cursor }, deleteBackward: { self.delete() }, insertText: { self.insert($0) })
    }
}

@MainActor
@Test(arguments: ["three words", "👩🏽‍💻🇭🇰e\u{301}", "👨‍👩‍👧‍👦"])
func realExecutorChecksEveryGraphemeAndPreservesAnchor(_ text: String) {
    let proxy = FakeProxy()
    let now = Date(timeIntervalSince1970: 100)
    let generation = UUID(), utterance = UUID()
    var policy = OwnedInsertion()
    let began = policy.begin(generation: generation, utteranceID: utterance, context: proxy.cursor, now: now)
    #expect(began)
    let first = TextEvent(generation: generation, utteranceID: utterance, kind: .partial,
                          text: text, createdAt: now, expiresAt: now.addingTimeInterval(30))
    let insertion = policy.plan(first, context: proxy.cursor, now: now, leaseUntil: first.expiresAt)!
    let inserted = proxy.apply(insertion)
    #expect(inserted)
    let confirmed = policy.didApply(insertion, observed: proxy.cursor, now: now)
    #expect(confirmed)
    var final = first
    final.id = UUID(); final.sequence = 1; final.kind = .final; final.text = "Final"
    let replacement = policy.plan(final, context: proxy.cursor, now: now, leaseUntil: first.expiresAt)!
    let replaced = proxy.apply(replacement)
    #expect(replaced)
    #expect(proxy.deletes == text.count)
    #expect(proxy.inserts == 2)
    #expect(proxy.cursor.before == "user: Final")
    #expect(proxy.cursor.after == " suffix")
}

@MainActor
@Test(arguments: [0, 1, 2, 3, 4])
func executorStopsAfterFirstUnexpectedDelete(_ mode: Int) {
    let proxy = FakeProxy()
    let baseline = proxy.cursor
    proxy.cursor.before = "user: mine"
    let plan = EditPlan(expected: proxy.cursor, ownedText: "mine", replacement: "final")
    proxy.afterDelete = { p in
        switch mode {
        case 0: p.cursor.documentID = UUID() // new document, SAME text after first deletion
        case 1: p.cursor.before = "different user's content"
        case 2: p.cursor.after = nil // unavailable/truncated host context
        case 3: p.cursor.selection = "selected"
        default: p.cursor.before = "user: mine" // host ignored deletion
        }
    }
    let applied = proxy.apply(plan)
    #expect(!applied)
    #expect(proxy.deletes == 1)
    #expect(proxy.inserts == 0)
    #expect(baseline.before == "user: ")
}

@MainActor
@Test func executorRefusesChangedDocumentBeforeFirstDeletion() {
    let proxy = FakeProxy()
    proxy.cursor.before = "user: mine"
    let plan = EditPlan(expected: proxy.cursor, ownedText: "mine", replacement: "final")
    proxy.cursor.documentID = UUID()
    let applied = proxy.apply(plan)
    #expect(!applied)
    #expect(proxy.deletes == 0)
    #expect(proxy.inserts == 0)
    #expect(proxy.cursor.before == "user: mine")
}

@Test(arguments: [false, true])
func cancelAndEndAfterFinalOrRawPreserveCommittedText(_ useRaw: Bool) {
    let now = Date(timeIntervalSince1970: 100)
    let generation = UUID(), utterance = UUID()
    var cursor = CursorContext(documentID: UUID(), before: "user: ", after: " suffix")
    var policy = OwnedInsertion()
    let began = policy.begin(generation: generation, utteranceID: utterance, context: cursor, now: now)
    #expect(began)
    var event = TextEvent(generation: generation, utteranceID: utterance, kind: .final, text: "Final",
                          createdAt: now, expiresAt: now.addingTimeInterval(30))
    var plan = policy.plan(event, context: cursor, now: now, leaseUntil: event.expiresAt)!
    cursor = plan.resultingContext
    let confirmed = policy.didApply(plan, observed: cursor, now: now)
    #expect(confirmed)
    if useRaw {
        event.id = UUID(); event.sequence = 1; event.kind = .raw; event.text = "um final"
        plan = policy.plan(event, context: cursor, now: now, leaseUntil: event.expiresAt, rawRequested: true)!
        cursor = plan.resultingContext
        let appliedRaw = policy.didApply(plan, observed: cursor, now: now)
        #expect(appliedRaw)
    }
    let committed = cursor
    let cancel = policy.cancel(context: cursor)
    #expect(cancel == nil)
    #expect(cursor == committed)
    policy.invalidate() // End session only invalidates; it does not request an edit.
    #expect(cursor == committed)
}
