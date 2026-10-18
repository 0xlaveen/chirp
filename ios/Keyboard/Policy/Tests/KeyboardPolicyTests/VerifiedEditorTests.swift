import Foundation
import Testing
@testable import KeyboardPolicy

@MainActor
private final class FakeProxy {
    var cursor = CursorContext(documentID: UUID(), before: "user: ", after: " suffix")
    var deletes = 0
    var inserts = 0
    var afterDelete: ((FakeProxy) -> Void)?
    var contextWindow: Int?

    func delete() {
        deletes += 1
        cursor.before?.removeLast()
        afterDelete?(self)
    }
    func insert(_ text: String) {
        inserts += 1; cursor.before = (cursor.before ?? "") + text
        if let contextWindow { cursor.before = String((cursor.before ?? "").suffix(contextWindow)) }
    }
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

@MainActor
@Test func twoThousandCharacterUtteranceSupportsEveryReplacementAndRaw() throws {
    let started = ContinuousClock.now
    defer { print("2K partial/correcting/final/raw executor duration: \(started.duration(to: .now))") }
    let proxy = FakeProxy()
    // Exercise an existing document context larger than the previous 256-unit cap.
    let anchor = String(repeating: "Existing user content. ", count: 30)
    proxy.cursor.before = anchor
    proxy.cursor.after = String(repeating: "Following user content. ", count: 30)
    let after = proxy.cursor.after
    let now = Date(timeIntervalSince1970: 100)
    let generation = UUID(), utterance = UUID()
    var policy = OwnedInsertion()
    let began = policy.begin(generation: generation, utteranceID: utterance, context: proxy.cursor, now: now)
    #expect(began)
    let kinds: [ResultKind] = [.partial, .correcting, .final, .raw]
    for (sequence, kind) in kinds.enumerated() {
        let phrase = ["First sentence. ", "More sentences. ", "Final sentence. ", "Raw transcript. "][sequence]
        let text = String((String(repeating: phrase, count: 140)).prefix(2_048))
        #expect(text.count == 2_048)
        let event = TextEvent(generation: generation, utteranceID: utterance, kind: kind, text: text,
                              sequence: sequence, createdAt: now, expiresAt: now.addingTimeInterval(30))
        let proposed = policy.plan(event, context: proxy.cursor, now: now,
                                   leaseUntil: event.expiresAt, rawRequested: kind == .raw)
        let plan = try #require(proposed)
        let applied = proxy.apply(plan)
        #expect(applied)
        let confirmed = policy.didApply(plan, observed: proxy.cursor, now: now)
        #expect(confirmed)
        #expect(proxy.cursor.before == anchor + text)
        #expect(proxy.cursor.after == after)
    }
    #expect(proxy.deletes == 3 * 2_048)
    #expect(proxy.inserts == 4)
    #expect(!policy.requiresRecovery)
}

@MainActor
@Test(arguments: [false, true])
func actualContextWindowTruncationRefusesLongReplacement(_ truncateDuringInsertion: Bool) throws {
    let proxy = FakeProxy()
    let now = Date(timeIntervalSince1970: 100)
    let generation = UUID(), utterance = UUID()
    var policy = OwnedInsertion()
    let began = policy.begin(generation: generation, utteranceID: utterance, context: proxy.cursor, now: now)
    #expect(began)
    let text = String(repeating: "word ", count: 410)
    var event = TextEvent(generation: generation, utteranceID: utterance, kind: .partial, text: text,
                          createdAt: now, expiresAt: now.addingTimeInterval(30))
    let proposed = policy.plan(event, context: proxy.cursor, now: now, leaseUntil: event.expiresAt)
    let plan = try #require(proposed)
    if truncateDuringInsertion { proxy.contextWindow = 64 }
    let applied = proxy.apply(plan)
    let confirmed = policy.didApply(plan, observed: proxy.cursor, now: now)
    if truncateDuringInsertion {
        #expect(!applied)
        #expect(!confirmed)
    } else {
        #expect(applied)
        #expect(confirmed)
        // The host subsequently exposes a shifted 64-character window. Even
        // with the same document ID and owned suffix, the original anchor is lost.
        proxy.cursor.before = String((proxy.cursor.before ?? "").suffix(64))
    }
    let preserved = proxy.cursor
    event.id = UUID(); event.sequence = 1; event.kind = .final
    #expect(policy.plan(event, context: proxy.cursor, now: now, leaseUntil: event.expiresAt) == nil)
    #expect(policy.requiresRecovery)
    #expect(proxy.deletes == 0)
    #expect(proxy.inserts == 1)
    #expect(proxy.cursor == preserved)
}
