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

    public init(documentID: UUID, before: String?, after: String?, selection: String? = nil,
                uncertain: Bool = false) {
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

    /// Revalidate immediately before EACH deletion. Never issue a stored length's
    /// worth of deleteBackward calls against an unchecked text proxy.
    public func permitsDeletion(context: CursorContext, remaining: String) -> Bool {
        guard context.isUsable, context.documentID == expected.documentID,
              context.after == expected.after, let initial = expected.before,
              initial.hasSuffix(ownedText) else { return false }
        let anchor = String(initial.dropLast(ownedText.count))
        return context.before == anchor + remaining && !remaining.isEmpty
    }

    public var insertionContext: CursorContext {
        var result = expected
        result.before = String((expected.before ?? "").dropLast(ownedText.count))
        return result
    }

    public var resultingContext: CursorContext {
        var result = insertionContext
        result.before = (result.before ?? "") + replacement
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
    public init(id: UUID = UUID(), generation: UUID, utteranceID: UUID, kind: ResultKind,
                text: String, sequence: Int = 0, createdAt: Date, expiresAt: Date) {
        self.id = id; self.generation = generation; self.utteranceID = utteranceID
        self.kind = kind; self.text = text; self.sequence = sequence; self.createdAt = createdAt; self.expiresAt = expiresAt
    }
}

public struct OwnedInsertion: Sendable {
    public private(set) var generation: UUID?
    public private(set) var utteranceID: UUID?
    public private(set) var ownedText = ""
    public private(set) var requiresRecovery = false
    public private(set) var isFinal = false
    private var expected: CursorContext?
    private var startedAt = Date.distantFuture
    private var lastSequence = -1
    private var seen = Set<UUID>()
    private var rawDeadline: Date?
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
        if event.kind == .final { isFinal = true; rawDeadline = now.addingTimeInterval(5) }
        if event.kind == .raw { rawDeadline = nil }
        return true
    }

    /// Cancel retracts only text still proven to be ours. It never accepts finals afterward.
    public mutating func cancel(context: CursorContext) -> EditPlan? {
        defer { invalidate() }
        guard !isFinal, context.isUsable, let expected, expected == context else { return nil }
        return EditPlan(expected: expected, ownedText: ownedText, replacement: "")
    }
}
