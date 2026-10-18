import Foundation
import Testing
@testable import KeyboardPolicy

private struct Fixture {
    let generation = UUID()
    let utterance = UUID()
    let now = Date(timeIntervalSince1970: 1_000)
    var cursor = CursorContext(documentID: UUID(), before: "A: ", after: " tail")
    var policy = OwnedInsertion()

    init() {
        let began = policy.begin(generation: generation, utteranceID: utterance, context: cursor, now: now)
        #expect(began)
    }

    func event(_ text: String, kind: ResultKind = .partial, sequence: Int = 0) -> TextEvent {
        TextEvent(generation: generation, utteranceID: utterance, kind: kind, text: text,
                  sequence: sequence, createdAt: now, expiresAt: now.addingTimeInterval(30))
    }

    mutating func apply(_ event: TextEvent, at: Date? = nil, raw: Bool = false) -> EditPlan? {
        let time = at ?? now
        guard let plan = policy.plan(event, context: cursor, now: time,
                                     leaseUntil: now.addingTimeInterval(60), rawRequested: raw) else { return nil }
        cursor = plan.resultingContext
        let applied = policy.didApply(plan, observed: cursor, now: time)
        #expect(applied)
        return plan
    }
}

@Test(arguments: ["hello", "👩🏽‍💻", "🇭🇰", "e\u{301}", "👨‍👩‍👧‍👦", "你好 🌙", "\r\n"])
func replacesOnlyOwnedGraphemes(_ text: String) {
    var f = Fixture()
    #expect(f.apply(f.event(text)) != nil)
    let replacement = f.event("finished", kind: .final, sequence: 1)
    let plan = f.policy.plan(replacement, context: f.cursor, now: f.now,
                             leaseUntil: f.now.addingTimeInterval(60))!
    var remaining = text
    while !remaining.isEmpty {
        #expect(plan.permitsDeletion(context: f.cursor, remaining: remaining))
        remaining.removeLast()
        f.cursor.before = "A: " + remaining
    }
    #expect(!plan.permitsDeletion(context: f.cursor, remaining: ""))
    #expect(plan.insertionContext.before == "A: ")
    #expect(plan.resultingContext.before == "A: finished")
    #expect(plan.resultingContext.after == " tail")
}

@Test(arguments: [0, 1, 2, 3, 4, 5, 6])
func refusesUncertainInitialContext(_ mode: Int) {
    var cursor = CursorContext(documentID: UUID(), before: "prefix", after: "suffix")
    switch mode {
    case 0: cursor.before = nil
    case 1: cursor.after = nil
    case 2: cursor.selection = "selected"
    case 3: cursor.uncertain = true
    case 4: cursor.before = String(repeating: "a", count: InsertionLimits.maximumContextUTF16 + 1)
    case 5: cursor.after = String(repeating: "a", count: InsertionLimits.maximumContextUTF16 + 1)
    default: cursor.before = String(repeating: "👩", count: InsertionLimits.maximumContextUTF16 / 2 + 1)
    }
    var policy = OwnedInsertion()
    let began = policy.begin(generation: UUID(), utteranceID: UUID(), context: cursor, now: Date())
    #expect(!began)
    #expect(policy.requiresRecovery)
}

@Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7])
func editsOrFieldChangesNeverAuthorizeReplacement(_ mode: Int) {
    var f = Fixture()
    #expect(f.apply(f.event("owned")) != nil)
    let saved = f.cursor
    switch mode {
    case 0: f.cursor.before = "A: user edit owned"
    case 1: f.cursor.before = "A: owne" // cursor moved left
    case 2: f.cursor.after = "d tail"
    case 3: f.cursor.documentID = UUID() // same text, another host/document
    case 4: f.cursor.selection = "owned"
    case 5: f.cursor.before = "owned" // host context window was truncated
    case 6: f.cursor.before = nil
    default: f.cursor.after = nil
    }
    #expect(f.apply(f.event("new final", kind: .final, sequence: 1)) == nil)
    #expect(f.policy.requiresRecovery)
    #expect(f.policy.generation == nil)
    // Restoring the text does not silently reacquire ownership.
    f.cursor = saved
    #expect(f.apply(f.event("late final", kind: .final, sequence: 2)) == nil)
}

@Test func staleForeignRepeatedExpiredEventsAreIgnored() {
    var f = Fixture()
    let first = f.event("one")
    #expect(f.apply(first) != nil)
    #expect(f.apply(first) == nil)
    var event = f.event("two", sequence: 1)
    event.generation = UUID()
    #expect(f.apply(event) == nil)
    event = f.event("two", sequence: 1); event.utteranceID = UUID()
    #expect(f.apply(event) == nil)
    event = f.event("two", sequence: 1); event.expiresAt = f.now
    #expect(f.apply(event) == nil)
    event = f.event("two", sequence: 1); event.createdAt = f.now.addingTimeInterval(-1)
    #expect(f.apply(event) == nil)
    event = f.event("two", sequence: 1); event.createdAt = f.now.addingTimeInterval(1)
    #expect(f.apply(event) == nil)
    #expect(f.apply(f.event("out of order", sequence: 0)) == nil)
    #expect(f.cursor.before == "A: one")
    #expect(f.apply(f.event("two", sequence: 1)) != nil) // timestamp ties are ordered by sequence
}

@Test func expiredLeaseCannotInsert() {
    var f = Fixture()
    #expect(f.policy.plan(f.event("text"), context: f.cursor, now: f.now, leaseUntil: f.now) == nil)
    #expect(f.cursor.before == "A: ")
}

@Test func partialCorrectingFinalRawAndDuplicateTerminalEvents() {
    var f = Fixture()
    #expect(f.apply(f.event("um one")) != nil)
    #expect(f.apply(f.event("um one two", kind: .correcting, sequence: 1)) != nil)
    #expect(f.apply(f.event("One, two.", kind: .final, sequence: 2)) != nil)
    #expect(f.policy.isFinal)
    #expect(f.apply(f.event("duplicate final", kind: .final, sequence: 3)) == nil)
    #expect(f.apply(f.event("late partial", sequence: 4)) == nil)
    #expect(f.apply(f.event("um one two", kind: .raw, sequence: 5)) == nil)
    #expect(f.apply(f.event("um one two", kind: .raw, sequence: 5), at: f.now.addingTimeInterval(4), raw: true) != nil)
    #expect(f.cursor.before == "A: um one two")
    #expect(f.apply(f.event("raw replay", kind: .raw, sequence: 6), raw: true) == nil)
}

@Test func rawExpiresAndCannotBeAppliedBeforeFinal() {
    var f = Fixture()
    #expect(f.apply(f.event("raw", kind: .raw), raw: true) == nil)
    // Rejected raw invalidates ownership; a new explicit utterance is necessary.
    f = Fixture()
    #expect(f.apply(f.event("Final", kind: .final)) != nil)
    #expect(f.apply(f.event("raw", kind: .raw, sequence: 1), at: f.now.addingTimeInterval(5), raw: true) == nil)
    #expect(f.cursor.before == "A: Final")
}

@Test func cancelOnlyRetractsVerifiedTextAndRejectsLateFinal() {
    var f = Fixture()
    #expect(f.apply(f.event("mine")) != nil)
    let plan = f.policy.cancel(context: f.cursor)
    #expect(plan?.resultingContext.before == "A: ")
    #expect(f.apply(f.event("late", kind: .final, sequence: 1)) == nil)
    #expect(f.policy.cancel(context: f.cursor) == nil)

    f = Fixture()
    #expect(f.apply(f.event("mine")) != nil)
    f.cursor.before = "A: mine plus user text"
    #expect(f.policy.cancel(context: f.cursor) == nil)
    #expect(f.cursor.before == "A: mine plus user text")
}

@Test func hostTransformationOrDifferentDeletionUnitStopsOwnership() {
    var f = Fixture()
    #expect(f.apply(f.event("👩🏽‍💻")) != nil)
    let plan = f.policy.plan(f.event("final", kind: .final, sequence: 1), context: f.cursor,
                             now: f.now, leaseUntil: f.now.addingTimeInterval(60))!
    // A host deleting a scalar rather than a grapheme must not trigger further deletes.
    f.cursor.before = "A: 👩🏽‍"
    #expect(!plan.permitsDeletion(context: f.cursor, remaining: ""))
    #expect(!plan.permitsDeletion(context: f.cursor, remaining: "👩🏽‍💻"))
    let applied = f.policy.didApply(plan, observed: f.cursor, now: f.now)
    #expect(!applied)
    #expect(f.policy.requiresRecovery)
}

@Test func hideReloadAndSessionGenerationChangesDoNotReacquire() {
    var f = Fixture()
    #expect(f.apply(f.event("mine")) != nil)
    f.policy.invalidate() // keyboard hides, reloads, or receives a field-change callback
    #expect(f.apply(f.event("final", kind: .final, sequence: 1)) == nil)
    let old = f.event("old generation", kind: .final, sequence: 2)
    let began = f.policy.begin(generation: UUID(), utteranceID: UUID(), context: f.cursor, now: f.now)
    #expect(began)
    #expect(f.apply(old) == nil)
    #expect(f.cursor.before == "A: mine")
}

@Test func oversizedResultsPreserveExistingContentForManualRecovery() {
    var f = Fixture()
    #expect(f.apply(f.event("mine")) != nil)
    #expect(f.apply(f.event(String(repeating: "x", count: InsertionLimits.maximumResultUTF16 + 1), kind: .final, sequence: 1)) == nil)
    #expect(f.cursor.before == "A: mine")
    #expect(f.policy.requiresRecovery)
}

@Test func emptyFinalDeletesOnlyStillVerifiedOwnedSuffix() {
    var f = Fixture()
    #expect(f.apply(f.event("noise")) != nil)
    let plan = f.apply(f.event("", kind: .final, sequence: 1))
    #expect(plan?.ownedText == "noise")
    #expect(f.cursor.before == "A: ")
    #expect(f.cursor.after == " tail")
}

@Test(arguments: ["\u{301}", "\u{fe0f}", "\u{200d}👩"])
func graphemeCannotAbsorbUserAnchor(_ suffix: String) {
    var f = Fixture()
    #expect(f.apply(f.event(suffix)) == nil)
    #expect(f.cursor.before == "A: ")
    #expect(f.policy.requiresRecovery)
}

@Test func cursorInsideGraphemeIsUncertain() {
    var cursor = CursorContext(documentID: UUID(), before: "e", after: "\u{301}")
    #expect(!cursor.isUsable)
    cursor.before = "👩\u{200d}"; cursor.after = "💻"
    #expect(!cursor.isUsable)
}

@Test(arguments: ["a", "👩", "界"])
func resultBoundsAcceptBoundaryAndRefuseUnicodeOverflowBeforeAnyEdit(_ unit: String) {
    var f = Fixture()
    let fitting = String(repeating: unit, count: InsertionLimits.maximumResultUTF16 / unit.utf16.count)
    #expect(fitting.utf16.count == InsertionLimits.maximumResultUTF16)
    // 8192 UTF16 implies at most 24576 UTF8 bytes (BMP scalars use at
    // most three each); emoji uses four bytes for two UTF16 units.
    #expect(fitting.utf8.count <= InsertionLimits.maximumResultUTF8)
    #expect(f.apply(f.event(fitting)) != nil)
    let prior = f.cursor
    #expect(f.apply(f.event(fitting + unit, kind: .final, sequence: 1)) == nil)
    #expect(f.cursor == prior)
    #expect(f.policy.requiresRecovery)
}

@Test func emojiBeyondBridgeByteLimitCannotPlanAnyWrite() {
    var f = Fixture()
    let tooLarge = String(repeating: "👩", count: InsertionLimits.maximumResultUTF8 / 4 + 1)
    #expect(tooLarge.utf8.count > InsertionLimits.maximumResultUTF8)
    #expect(f.apply(f.event(tooLarge)) == nil)
    #expect(f.cursor.before == "A: ")
    #expect(f.policy.requiresRecovery)
}
