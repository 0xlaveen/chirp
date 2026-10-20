import Foundation

/// One committed segment of a Live Notes recording: an ordinary utterance's final, or a gap where it failed.
public struct NotesSegment: Equatable, Sendable, Identifiable {
    public var id: Int
    /// Seconds from the start of the session to the segment's first audio.
    public var offset: TimeInterval
    public var raw: String
    /// The corrected text, or the raw text when correction was off or failed.
    public var text: String
    public var corrected: Bool
    /// Correction was asked for but did not deliver, so the raw text was kept.
    public var keptOriginal: Bool
    /// Set for a gap: why this stretch of audio was not transcribed.
    public var failure: String?

    public init(id: Int, offset: TimeInterval, raw: String, text: String? = nil, corrected: Bool = false,
                keptOriginal: Bool = false, failure: String? = nil) {
        self.id = id
        self.offset = offset
        self.raw = raw
        self.text = text ?? raw
        self.corrected = corrected
        self.keptOriginal = keptOriginal
        self.failure = failure
    }

    public static func gap(id: Int, offset: TimeInterval, reason: String) -> NotesSegment {
        NotesSegment(id: id, offset: offset, raw: "", failure: reason)
    }

    public var isGap: Bool { failure != nil }
}

/// A frozen stretch of notes: Markdown that no later pass changes, and the segments it covers.
public struct NotesBlock: Equatable, Sendable {
    public var markdown: String
    public var segmentRange: ClosedRange<Int>
    /// Structuring never delivered for this stretch: the corrected text under "Not structured — see transcript".
    public var isFallback: Bool

    public init(markdown: String, segmentRange: ClosedRange<Int>, isFallback: Bool = false) {
        self.markdown = markdown
        self.segmentRange = segmentRange
        self.isFallback = isFallback
    }
}

/// Everything a Live Notes session holds, in memory only: the transcript segments, the frozen Markdown blocks and the
/// open window that the next structuring pass rewrites. Nothing here is persisted or logged; it goes away on New,
/// a discarded close or quit, and reaches disk only through an explicit Save….
public struct NotesDocument: Equatable, Sendable {
    /// The open window freezes once a pass succeeded on at least this many transcript characters (from the M1 bench:
    /// longer windows lose guard pass rate on the default Qwen).
    public static let freezeChars = 1600
    /// The open window never grows past this (the server takes up to 6000, but 4000-char windows hit the 768-token
    /// output cap): it freezes as a fallback block instead.
    public static let maxWindowChars = 3600
    public static let maxOutlineItems = 24
    public static let maxOutlineItemChars = 120
    public static let maxOutlineChars = 1500
    public static let fallbackHeader = "_Not structured — see transcript_"

    public private(set) var segments: [NotesSegment] = []
    public private(set) var frozen: [NotesBlock] = []
    /// The last good Markdown for the open window.
    public private(set) var openBlock: String?
    /// The first segment index of the open window.
    public private(set) var windowStart = 0
    /// The last segment index `openBlock` covers; -1 before any pass succeeded in this window.
    public private(set) var structuredEnd = -1
    public private(set) var consecutiveFailures = 0
    /// The current segment's live partial. Display only: never exported.
    public var livePartial = ""
    /// There is content that was not saved with Save… (Copy does not count).
    public private(set) var isDirty = false
    public private(set) var startedAt: Date

    public init(startedAt: Date = Date()) { self.startedAt = startedAt }

    /// Nothing to show, copy or save.
    public var isEmpty: Bool { !segments.contains { !$0.isGap && !$0.text.isEmpty } }

    // MARK: adding content

    /// Commits the next segment (the recorder keeps them in order).
    public mutating func append(_ segment: NotesSegment) {
        var s = segment
        s.id = segments.count
        segments.append(s)
        if !s.isGap, !s.text.isEmpty { isDirty = true }
    }

    public mutating func markSaved() { isDirty = false }

    // MARK: the open window

    /// The open window's segments that carry text.
    var windowSegments: [NotesSegment] {
        guard windowStart < segments.count else { return [] }
        return segments[windowStart...].filter { !$0.isGap && !$0.text.isEmpty }
    }

    /// Transcript characters in the open window, up to segment index `end` (all of it when nil).
    public func windowChars(through end: Int? = nil) -> Int {
        windowSegments.filter { $0.id <= (end ?? Int.max) }.reduce(0) { $0 + $1.text.count }
    }

    /// The window's text that no pass has structured yet: the notes pane's grey tail.
    public var unstructuredTail: String {
        windowSegments.filter { $0.id > structuredEnd }.map(\.text).joined(separator: " ")
    }

    /// The `##`/`###` headings of the frozen blocks, oldest first.
    public var headings: [String] {
        frozen.filter { !$0.isFallback }.flatMap { NotesMarkdown.headings($0.markdown) }
    }

    /// The outline sent with a pass: the newest headings, each at most 120 chars, at most 24 and 1500 chars in all.
    public var outline: [String] {
        var items = headings.suffix(Self.maxOutlineItems).map { String($0.prefix(Self.maxOutlineItemChars)) }
        while items.reduce(0, { $0 + $1.count }) > Self.maxOutlineChars { items.removeFirst() }
        return items
    }

    /// The next pass, or nil when the open window has no text a successful pass has not already seen.
    public func nextStructureRequest(final: Bool = false) -> NotesStructureRequest? {
        let window = windowSegments
        guard let last = window.last, last.id > structuredEnd else { return nil }
        let transcript = window.map(\.text).joined(separator: "\n")
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NotesStructureRequest(transcript: transcript, outline: outline, final: final, windowEnd: segments.count - 1)
    }

    /// Takes a pass's answer. A success replaces the open block (and freezes it once the window is long enough); a
    /// failure keeps the previous one. Either way the window is frozen as a fallback when it grows too long or keeps
    /// failing, so the session never wedges. A response for a window that has since been frozen is ignored.
    public mutating func apply(_ response: NotesStructureResponse, for request: NotesStructureRequest) {
        guard request.windowEnd >= windowStart, request.windowEnd < segments.count, request.windowEnd > structuredEnd else { return }
        if response.structured, let md = response.markdown?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty {
            openBlock = md
            structuredEnd = request.windowEnd
            consecutiveFailures = 0
            if windowChars(through: request.windowEnd) >= Self.freezeChars { freezeOpenBlock() }
        } else {
            consecutiveFailures += 1
        }
        freezeOverflow()
    }

    /// Freezes the window as a fallback when it is past `maxWindowChars`, or past `freezeChars` after two failures in a row.
    public mutating func freezeOverflow() {
        let chars = windowChars()
        guard chars > Self.maxWindowChars || (consecutiveFailures >= 2 && chars >= Self.freezeChars) else { return }
        freezeOpenBlock()
        freezeFallback()
        consecutiveFailures = 0
    }

    /// At Stop, after the final pass: the open block freezes, and with structuring on, whatever it did not cover
    /// freezes as a fallback. Recording again continues the same document with a new window.
    public mutating func freezeAll(structuring: Bool = true) {
        freezeOpenBlock()
        if structuring { freezeFallback() }
        consecutiveFailures = 0
    }

    private mutating func freezeOpenBlock() {
        guard let md = openBlock, structuredEnd >= windowStart else { openBlock = nil; return }
        frozen.append(NotesBlock(markdown: md, segmentRange: windowStart...structuredEnd))
        windowStart = structuredEnd + 1
        openBlock = nil
    }

    private mutating func freezeFallback() {
        let rest = windowSegments
        if let first = rest.first, let last = rest.last {
            let body = rest.map(\.text).joined(separator: "\n\n")
            frozen.append(NotesBlock(markdown: Self.fallbackHeader + "\n\n" + body, segmentRange: first.id...last.id, isFallback: true))
        }
        windowStart = segments.count
        structuredEnd = windowStart - 1
        openBlock = nil
    }

    // MARK: export

    /// `[hh:mm:ss]` from the session start.
    public static func timestamp(_ offset: TimeInterval) -> String {
        let s = max(0, Int(offset.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    public func title(timeZone: TimeZone = .current) -> String {
        "# Notes — " + Self.formatter("yyyy-MM-dd HH:mm", timeZone).string(from: startedAt)
    }

    /// `Chirp Notes 2026-10-20 1403.md`.
    public func suggestedFileName(timeZone: TimeZone = .current) -> String {
        "Chirp Notes " + Self.formatter("yyyy-MM-dd HHmm", timeZone).string(from: startedAt) + ".md"
    }

    /// The notes body: frozen blocks, then the open block, without placeholders.
    public var notesBody: String {
        (frozen.map(\.markdown) + [openBlock].compactMap { $0 })
            .map { $0.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.trimmingCharacters(in: .whitespaces) != NotesMarkdown.placeholder }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// One line per segment: `**[00:00:12]** text`, gaps and "kept original" marked. `raw` swaps in the raw text.
    public func transcriptLines(raw: Bool = false) -> [String] {
        segments.map { s in
            let stamp = "**[\(Self.timestamp(s.offset))]** "
            if let failure = s.failure { return stamp + "⚠︎ audio not transcribed (\(failure))" }
            return stamp + (raw ? s.raw : s.text) + (s.keptOriginal && !raw ? " _(kept original)_" : "")
        }
    }

    public func transcriptMarkdown(raw: Bool = false) -> String {
        (["## Transcript"] + transcriptLines(raw: raw)).joined(separator: "\n")
    }

    /// Save…'s format: the title, the notes, then the transcript appendix. With structuring unavailable (or no notes
    /// yet) only the transcript section follows the title.
    public func exportMarkdown(includeTranscript: Bool = true, structuring: Bool = true, timeZone: TimeZone = .current) -> String {
        var parts = [title(timeZone: timeZone)]
        let body = structuring ? notesBody : ""
        if !body.isEmpty { parts.append(body) }
        if includeTranscript || body.isEmpty {
            if !body.isEmpty { parts.append("---") }
            parts.append(transcriptMarkdown())
        }
        return parts.joined(separator: "\n\n") + "\n"
    }
}
