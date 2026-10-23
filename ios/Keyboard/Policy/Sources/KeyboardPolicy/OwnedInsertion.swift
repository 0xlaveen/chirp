import Foundation

/// Resource bounds accommodate multi-sentence dictation within the app's 120-second
/// utterance limit. They are not evidence that a host context is complete.
public enum InsertionLimits {
    public static let maximumResultUTF16 = 8_192
    public static let maximumResultUTF8 = 65_536 // SharedBridge publication limit.
    public static let maximumContextUTF16 = 16_384
}

/// UIKit does not report whether its context is complete. A moving/truncated
/// window therefore loses ownership even when it is below the resource bounds.
public struct CursorContext: Equatable, Sendable {
    public var documentID: UUID
    public var before: String?
    public var after: String?
    public var selection: String?
    public var uncertain: Bool

    /// UIKit reports `nil` for the context before the caret at the start of a document and after it at the
    /// end, and `nil` for both in an empty field. `nil` is normalised to `""` only where that is provable:
    /// one side `nil` while the other is present (caret at the start/end), or both `nil` with
    /// `hasText == false` (empty field). Both `nil` without that proof, or a `hasText` that contradicts the
    /// context, stays unusable. `VerifiedEditor` still re-checks the host after every edit.
    public init(documentID: UUID, before: String?, after: String?, selection: String? = nil,
                hasText: Bool? = nil, uncertain: Bool = false) {
        var before = before, after = after, uncertain = uncertain
        if before == nil, after != nil { before = "" }
        else if after == nil, before != nil { after = "" }
        else if before == nil, after == nil, hasText == false { before = ""; after = "" }
        if let hasText, hasText != !((before ?? "").isEmpty && (after ?? "").isEmpty && (selection ?? "").isEmpty),
           before != nil, after != nil {
            uncertain = true // hasText disagrees with the reported context
        }
        self.documentID = documentID
        self.before = before
        self.after = after
        self.selection = selection
        self.uncertain = uncertain
    }

    public var isUsable: Bool {
        guard !uncertain, let before, let after else { return false }
        return (selection ?? "").isEmpty &&
            before.utf16.count <= InsertionLimits.maximumContextUTF16 &&
            after.utf16.count <= InsertionLimits.maximumContextUTF16 &&
            (before + after).count == before.count + after.count
    }
}

public struct EditPlan: Equatable, Sendable {
    public let expected: CursorContext
    public let ownedText: String
    public let replacement: String

    /// Leading characters (of the replacement) that the owned text already shows. They stay in the editor, so a
    /// growing partial only rewrites its changed tail instead of deleting and retyping the whole utterance.
    public var keptPrefix: String {
        String(replacement.prefix(zip(ownedText, replacement).prefix { $0 == $1 }.count))
    }
    /// The owned characters to delete (after `keptPrefix`) and the characters to insert in their place.
    public var deletedText: String { String(ownedText.dropFirst(keptPrefix.count)) }
    public var insertedText: String { String(replacement.dropFirst(keptPrefix.count)) }

    /// Revalidate immediately before EACH deletion. Never issue a stored length's
    /// worth of deleteBackward calls against an unchecked text proxy.
    public func permitsDeletion(context: CursorContext, remaining: String) -> Bool {
        guard context.isUsable, context.documentID == expected.documentID,
              context.after == expected.after, let initial = expected.before,
              initial.hasSuffix(ownedText) else { return false }
        let anchor = String(initial.dropLast(ownedText.count))
        return context.before == anchor + keptPrefix + remaining && !remaining.isEmpty
    }

    /// The editor once the changed tail is deleted: everything up to and including `keptPrefix`.
    public var insertionContext: CursorContext {
        var result = expected
        result.before = String((expected.before ?? "").dropLast(ownedText.count)) + keptPrefix
        return result
    }

    public var resultingContext: CursorContext {
        var result = insertionContext
        result.before = (result.before ?? "") + insertedText
        return result
    }
}

public enum ResultKind: Sendable { case partial, correcting, final, raw }

public struct TextEvent: Sendable {
    public var id: UUID
    public var generation: UUID
    public var utteranceID: UUID
    public var kind: ResultKind
    public var text: String
    public var sequence: Int
    public var createdAt: Date
    public var expiresAt: Date
    /// Long dictation segment, 0 for the first.
    public var segment: Int
    public init(id: UUID = UUID(), generation: UUID, utteranceID: UUID, kind: ResultKind,
                text: String, sequence: Int = 0, createdAt: Date, expiresAt: Date, segment: Int = 0) {
        self.id = id; self.generation = generation; self.utteranceID = utteranceID
        self.kind = kind; self.text = text; self.sequence = sequence; self.createdAt = createdAt; self.expiresAt = expiresAt
        self.segment = segment
    }
}

public struct OwnedInsertion: Sendable {
    public private(set) var generation: UUID?
    public private(set) var utteranceID: UUID?
    public private(set) var ownedText = ""
    public private(set) var requiresRecovery = false
    public private(set) var isFinal = false
    /// Long dictation: the segment this keyboard currently owns. Earlier segments' text is no longer ours.
    public private(set) var segment = 0
    private var expected: CursorContext?
    private var startedAt = Date.distantFuture
    private var lastSequence = -1
    private var seen = Set<UUID>()
    private var rawDeadline: Date?
    private var undoDeadline: Date?
    private var pendingEvent: TextEvent?

    public init() {}

    @discardableResult
    public mutating func begin(generation: UUID, utteranceID: UUID, context: CursorContext,
                               now: Date) -> Bool {
        self = Self()
        guard context.isUsable else { requiresRecovery = true; return false }
        self.generation = generation; self.utteranceID = utteranceID
        expected = context; startedAt = now
        return true
    }

    public mutating func invalidate() {
        requiresRecovery = generation != nil || requiresRecovery
        expected = nil; generation = nil; utteranceID = nil; pendingEvent = nil
        ownedText = ""; seen.removeAll(); rawDeadline = nil
    }

    public mutating func plan(_ event: TextEvent, context: CursorContext, now: Date,
                              leaseUntil: Date, rawRequested: Bool = false) -> EditPlan? {
        guard event.generation == generation, event.utteranceID == utteranceID,
              !seen.contains(event.id), event.expiresAt > now,
              event.createdAt >= startedAt, event.createdAt <= now,
              leaseUntil > now else { return nil }
        // The encrypted bridge publishes an increasing sequence per utterance.
        guard event.sequence > lastSequence else { return nil }
        if event.segment > segment {
            // The previous segment landed; the next one starts right after it and owns nothing yet. Only hand
            // over where we left the editor, so landed text is never touched again.
            guard isFinal, event.segment == segment + 1, event.kind != .raw, let expected, context == expected else {
                invalidate(); return nil
            }
            segment = event.segment; ownedText = ""; isFinal = false; rawDeadline = nil; undoDeadline = nil
        } else if event.segment < segment { return nil }
        guard !isFinal || (event.kind == .raw && rawRequested && now < (rawDeadline ?? .distantPast)) else {
            return nil
        }
        guard event.kind != .raw || (isFinal && rawRequested), context.isUsable,
              let expected, context == expected,
              event.text.utf16.count <= InsertionLimits.maximumResultUTF16,
              event.text.utf8.count <= InsertionLimits.maximumResultUTF8,
              ((expected.before ?? "").utf16.count - ownedText.utf16.count + event.text.utf16.count)
                <= InsertionLimits.maximumContextUTF16 else {
            invalidate(); return nil
        }
        let anchor = String((expected.before ?? "").dropLast(ownedText.count))
        let after = expected.after ?? ""
        // A leading combining mark / ZWJ must never absorb the user's previous
        // grapheme into our suffix. The same rule applies to the following text.
        guard (anchor + event.text).count == anchor.count + event.text.count,
              (anchor + event.text + after).count == anchor.count + event.text.count + after.count else {
            invalidate(); return nil
        }
        seen.insert(event.id); lastSequence = event.sequence; pendingEvent = event
        return EditPlan(expected: expected, ownedText: ownedText, replacement: event.text)
    }

    /// Ownership transfers only after the host actually exposes the exact result.
    public mutating func didApply(_ plan: EditPlan, observed: CursorContext, now: Date) -> Bool {
        guard let event = pendingEvent, observed == plan.resultingContext, observed.isUsable else {
            invalidate(); return false
        }
        expected = observed; ownedText = plan.replacement; pendingEvent = nil
        if event.kind == .final { isFinal = true; rawDeadline = now.addingTimeInterval(5); undoDeadline = rawDeadline }
        if event.kind == .raw { rawDeadline = nil }
        return true
    }

    /// Undo is offered for 5 seconds after a final lands (Android's window).
    public func canUndo(now: Date) -> Bool { isFinal && generation != nil && now < (undoDeadline ?? .distantPast) }

    /// Removes exactly the landed dictation, only while the editor still shows it as we left it. After
    /// applying the plan, call `release()`; there is nothing left to own.
    public func undo(context: CursorContext, now: Date) -> EditPlan? {
        guard canUndo(now: now), context.isUsable, let expected, expected == context, !ownedText.isEmpty else { return nil }
        return EditPlan(expected: expected, ownedText: ownedText, replacement: "")
    }

    /// Forgets the utterance without asking for recovery: the dictation was undone or deliberately let go.
    public mutating func release() { self = Self() }

    /// Cancel retracts only text still proven to be ours. It never accepts finals afterward.
    public mutating func cancel(context: CursorContext) -> EditPlan? {
        defer { invalidate() }
        guard !isFinal, context.isUsable, let expected, expected == context else { return nil }
        return EditPlan(expected: expected, ownedText: ownedText, replacement: "")
    }
}
