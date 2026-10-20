import Foundation
import Testing
@testable import KeyboardPolicy

/// Mimics UIKit's nil conventions: no `before` at the start of the document, no `after` at the end,
/// neither in an empty field. `mode` makes the host lie in the ways the safety model must survive.
@MainActor
private final class UIKitHost {
    enum Quirk { case none, ignoresInsert, hidesBothSides, reportsEmptyAfterAsEmptyString }
    let document = UUID()
    var text: [Character]
    var caret: Int
    var quirk = Quirk.none
    var deletes = 0

    init(_ text: String, caret: Int? = nil) { self.text = Array(text); self.caret = caret ?? text.count }

    var context: CursorContext {
        let before = String(text[..<caret]), after = String(text[caret...])
        switch quirk {
        case .hidesBothSides: return CursorContext(documentID: document, before: nil, after: nil, hasText: !text.isEmpty)
        case .reportsEmptyAfterAsEmptyString:
            return CursorContext(documentID: document, before: before.isEmpty ? nil : before, after: after, hasText: !text.isEmpty)
        default:
            return CursorContext(documentID: document, before: before.isEmpty ? nil : before,
                                 after: after.isEmpty ? nil : after, hasText: !text.isEmpty)
        }
    }
    func insert(_ s: String) { guard quirk != .ignoresInsert else { return }; text.insert(contentsOf: s, at: caret); caret += s.count }
    func delete() { deletes += 1; if caret > 0 { text.remove(at: caret - 1); caret -= 1 } }
    var value: String { String(text) }
    func apply(_ plan: EditPlan) -> Bool {
        VerifiedEditor.apply(plan, context: { self.context }, deleteBackward: { self.delete() }, insertText: { self.insert($0) })
    }
}

private let now = Date(timeIntervalSince1970: 500)

@MainActor
private func run(_ host: UIKitHost, partial: String = "synthetic words", final: String = "Synthetic words.") -> (began: Bool, value: String) {
    let generation = UUID(), utterance = UUID()
    var policy = OwnedInsertion()
    guard policy.begin(generation: generation, utteranceID: utterance, context: host.context, now: now) else {
        return (false, host.value)
    }
    for (index, (kind, text)) in [(ResultKind.partial, partial), (.final, final)].enumerated() {
        let event = TextEvent(generation: generation, utteranceID: utterance, kind: kind, text: text, sequence: index,
                              createdAt: now, expiresAt: now.addingTimeInterval(30))
        guard let plan = policy.plan(event, context: host.context, now: now, leaseUntil: now.addingTimeInterval(30)),
              host.apply(plan), policy.didApply(plan, observed: host.context, now: now) else { return (true, host.value) }
    }
    return (true, host.value)
}

@Suite struct CursorContextNormalisationTests {
    private let doc = UUID()
    private func make(_ before: String?, _ after: String?, hasText: Bool? = nil, selection: String? = nil) -> CursorContext {
        CursorContext(documentID: doc, before: before, after: after, selection: selection, hasText: hasText)
    }

    @Test func emptyFieldIsUsableOnlyWithHasTextFalse() {
        let empty = make(nil, nil, hasText: false)
        #expect(empty.isUsable && empty.before == "" && empty.after == "")
        #expect(!make(nil, nil).isUsable)
        #expect(!make(nil, nil, hasText: true).isUsable)
    }

    @Test func caretAtStartAndEndNormaliseTheMissingSide() {
        let start = make(nil, "tail", hasText: true)
        #expect(start.isUsable && start.before == "" && start.after == "tail")
        for after in [nil, ""] as [String?] {
            let end = make("head ", after, hasText: true)
            #expect(end.isUsable && end.before == "head " && end.after == "")
        }
        #expect(make(nil, "tail").isUsable && make("head", nil).isUsable)
    }

    @Test func contradictoryHasTextIsRefused() {
        #expect(!make("head", "tail", hasText: false).isUsable)
        #expect(!make("head", nil, hasText: false).isUsable)
        #expect(!make(nil, "tail", hasText: false).isUsable)
        #expect(!make("", "", hasText: true).isUsable)
        #expect(!make("head", nil, hasText: false).isUsable)
    }

    @Test func selectionAndExplicitUncertaintyStillRefuse() {
        #expect(!make("a", "b", hasText: true, selection: "x").isUsable)
        #expect(!CursorContext(documentID: doc, before: "a", after: "b", hasText: true, uncertain: true).isUsable)
        // A selection with nothing around it still has text, so hasText true is consistent but unusable.
        #expect(!make(nil, nil, hasText: true, selection: "x").isUsable)
    }

    @Test func equalityIsStableAcrossNilAndEmptySpellings() {
        #expect(make(nil, "x", hasText: true) == make("", "x", hasText: true))
        #expect(make("x", nil, hasText: true) == make("x", "", hasText: true))
        #expect(make(nil, nil, hasText: false) == make("", "", hasText: false))
    }
}

@MainActor @Suite struct UIKitNilConventionTests {
    @Test func emptyFieldDictatesPartialThenFinal() {
        let host = UIKitHost("")
        let result = run(host)
        #expect(result.began && result.value == "Synthetic words.")
    }

    @Test func caretAtDocumentStartKeepsFollowingText() {
        let host = UIKitHost("Host prefix. ", caret: 0)
        let result = run(host)
        #expect(result.began && result.value == "Synthetic words.Host prefix. ")
    }

    @Test func caretAtEndWithNilAfterKeepsPrefix() {
        let host = UIKitHost("Host prefix. ")
        let result = run(host)
        #expect(result.began && result.value == "Host prefix. Synthetic words.")
    }

    @Test func caretAtEndWithEmptyStringAfterKeepsPrefix() {
        let host = UIKitHost("Host prefix. "); host.quirk = .reportsEmptyAfterAsEmptyString
        let result = run(host)
        #expect(result.began && result.value == "Host prefix. Synthetic words.")
    }

    @Test func caretInTheMiddleStillWorks() {
        let host = UIKitHost("ab cd", caret: 3)
        #expect(run(host).value == "ab Synthetic words.cd")
    }

    @Test func ambiguousNilOnBothSidesIsRefusedBeforeAnyEdit() {
        let host = UIKitHost("Host prefix. "); host.quirk = .hidesBothSides
        let result = run(host)
        #expect(!result.began && result.value == "Host prefix. " && host.deletes == 0)
    }

    @Test func hostThatIgnoresInsertionNeverDeletes() {
        let host = UIKitHost("keep me"); host.quirk = .ignoresInsert
        let result = run(host)
        #expect(result.began && result.value == "keep me" && host.deletes == 0)
    }

    @Test func emptyFieldCancelRetractsOnlyOwnedPartial() {
        let host = UIKitHost("")
        let generation = UUID(), utterance = UUID()
        var policy = OwnedInsertion()
        let began = policy.begin(generation: generation, utteranceID: utterance, context: host.context, now: now)
        #expect(began)
        let event = TextEvent(generation: generation, utteranceID: utterance, kind: .partial, text: "abc", sequence: 0,
                              createdAt: now, expiresAt: now.addingTimeInterval(30))
        let plan = policy.plan(event, context: host.context, now: now, leaseUntil: now.addingTimeInterval(30))!
        let inserted = host.apply(plan)
        let owned = policy.didApply(plan, observed: host.context, now: now)
        #expect(inserted && owned)
        let cancel = policy.cancel(context: host.context)!
        let retracted = host.apply(cancel)
        #expect(retracted && host.value == "" && host.deletes == 3)
    }
}
