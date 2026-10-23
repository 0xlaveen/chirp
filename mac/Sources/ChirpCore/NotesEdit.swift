import Foundation

/// `POST /v1/notes/edit` (#97): one spoken instruction applied to part of the notes. Only `notes` and `instruction`
/// go on the wire; the scope (`range`), the document and its `version` stay on the client, so the answer applies only
/// to the text it was made from. Never logged.
public struct NotesEditRequest: Encodable, Sendable, Equatable {
    public var notes: String
    public var instruction: String
    public var range: NSRange
    public var documentID: UUID?
    public var version: Int

    public init(notes: String, instruction: String, range: NSRange = NSRange(), documentID: UUID? = nil, version: Int = 0) {
        self.notes = notes
        self.instruction = instruction
        self.range = range
        self.documentID = documentID
        self.version = version
    }

    private enum CodingKeys: String, CodingKey { case notes, instruction }
}

/// The edit answer. `edited:false` fails closed (`markdown` nil); `error: "refused"` means the instruction asks for
/// something an edit may not do (`reason`: `adds_content`, `unclear`, `not_an_edit`); `changed:false` means nothing
/// to apply; `error: "preempted"` means a segment clean-up took the model first (it did not run).
public struct NotesEditResponse: Decodable, Sendable, Equatable {
    public var markdown: String?
    public var edited: Bool
    public var changed: Bool
    public var error: String?
    public var reason: String?

    public init(markdown: String?, edited: Bool, changed: Bool = true, error: String? = nil, reason: String? = nil) {
        self.markdown = markdown
        self.edited = edited
        self.changed = changed
        self.error = error
        self.reason = reason
    }

    public var failureLabel: String { NotesFailure.label(error: error, reason: reason) }
    public var preempted: Bool { !edited && error == "preempted" }
    /// The refusal reason (a code, never text), when the server refused the instruction.
    public var refusal: String? { !edited && error == "refused" ? NotesFailure.guardName(reason) ?? "unclear" : nil }

    public static func failed(_ code: String) -> NotesEditResponse {
        NotesEditResponse(markdown: nil, edited: false, changed: false, error: code)
    }

    private enum CodingKeys: String, CodingKey { case markdown, edited, changed, error, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown)
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        changed = try c.decodeIfPresent(Bool.self, forKey: .changed) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        if markdown == nil { edited = false; changed = false }
    }
}

/// How one voice edit ended.
public enum NotesEditOutcome: Equatable, Sendable {
    case applied
    /// The model found nothing to change.
    case unchanged
    /// The server refused the instruction (`adds_content`, `unclear`, `not_an_edit`).
    case refused(String)
    /// The notes changed while it ran (typing, a composition): nothing was applied.
    case conflict
    /// Nothing to edit: no notes, or a selection over the limit (`empty`, `too_long`).
    case nothing(String)
    /// The call failed or the guards rejected the answer (`rejected: dropped_line`, `timeout`, `busy`…).
    case failed(String)
}

/// What a voice edit may change: a UTF-16 range of the notes, or why there is none (`empty`, `too_long`).
public enum NotesEditScope: Equatable, Sendable {
    case range(NSRange)
    case nothing(String)
}

extension NotesDocument {
    /// What an instruction may edit: the selected lines, else the whole notes, else (past `maxReorganizeChars`) the
    /// trailing whole sections that fit. `nothing` says why there is no scope.
    public func editScope(selection: NSRange?) -> NotesEditScope {
        let ns = text as NSString
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing("empty") }
        if let selection, selection.length > 0, NSMaxRange(selection) <= ns.length {
            let lines = ns.lineRange(for: selection)
            guard !ns.substring(with: lines).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .nothing("empty")
            }
            return ns.substring(with: lines).unicodeScalars.count <= Self.maxReorganizeChars
                ? .range(lines) : .nothing("too_long")
        }
        if text.unicodeScalars.count <= Self.maxReorganizeChars { return .range(NSRange(location: 0, length: ns.length)) }
        return reorganizeScope().map { .range($0.range) } ?? .nothing("too_long")
    }

    /// The request for `instruction` over `range`, without the blank lines that frame it.
    public func editRequest(_ instruction: String, range: NSRange) -> NotesEditRequest {
        NotesEditRequest(notes: (text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines),
                         instruction: instruction, range: range, documentID: id, version: version)
    }

    /// Applies an edit answer as one change (a user edit: it is the user's instruction, so a touched AI tail becomes
    /// theirs), only when the notes are exactly what the request was made from. Nil otherwise, or when there is
    /// nothing to apply.
    public mutating func applyEdit(_ response: NotesEditResponse, for request: NotesEditRequest) -> NotesTextChange? {
        guard canApplyEdit(request), response.edited, response.changed,
              let md = response.markdown?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty else { return nil }
        let old = (text as NSString).substring(with: request.range)
        let lead = String(old.prefix { $0.isNewline })
        let trail = String(old.reversed().prefix { $0.isWhitespace }.reversed())
        return userEdit(request.range, lead + md + trail, kind: .edit)
    }

    /// The request still describes this text: same document, and no change to the notes since (any edit anywhere,
    /// even outside the scope, counts: the user may have meant it with the old text in view).
    public func canApplyEdit(_ request: NotesEditRequest) -> Bool {
        request.documentID == id && request.version == version && NSMaxRange(request.range) <= count
    }
}
