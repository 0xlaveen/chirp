import Foundation

/// The notes as they were before an applied reorganize, Organize or re-transcribe rebuild, so the user can read what
/// it changed and take it back. In memory only (never logged, never journalled); the last `NotesSnapshots.limit` are
/// kept and New drops them.
public struct NotesSnapshot: Equatable, Sendable, Identifiable {
    public let id: Int
    public let at: Date
    /// The text before, and the text the reorganize left (it grows with the steps of one Organize run).
    public let before: String
    public var after: String
    /// The whole-document Organize run it belongs to (one snapshot per run).
    let run: Int?
    /// A re-transcribe rebuilt the notes (the review says "Notes rebuilt").
    public var rebuild = false
}

public struct NotesSnapshots: Equatable, Sendable {
    public static let limit = 5

    /// Oldest first.
    public private(set) var items: [NotesSnapshot] = []
    private var nextID = 0

    public init() {}

    public var latest: NotesSnapshot? { items.last }
    public func snapshot(_ id: Int) -> NotesSnapshot? { items.first { $0.id == id } }
    public mutating func removeAll() { items.removeAll() }
    public mutating func remove(_ id: Int) { items.removeAll { $0.id == id } }

    /// Replays `changes` (as the document applied them) from `text`, the notes before them: every reorganize or
    /// Organize run in them keeps a snapshot of the text right before it. A whole-document Organize arrives in steps
    /// across several calls and stays one snapshot. When the replay does not end at `result`, a user edit got in
    /// between and nothing is kept.
    public mutating func record(_ changes: [NotesTextChange], from text: String, result: String, at: Date) {
        var current = text
        var staged: [(before: String, after: String, run: Int?, grouped: Bool, rebuild: Bool)] = []
        for change in changes {
            let before = current
            guard NSMaxRange(change.range) <= (current as NSString).length else { return }
            current = change.applied(to: current)
            guard change.kind == .reorganize || change.kind == .organize || change.kind == .rebuild else { continue }
            if let last = staged.last, last.grouped, change.kind == .organize || (change.run != nil && change.run == last.run) {
                staged[staged.count - 1].after = current
            } else {
                staged.append((before, current, change.run, change.kind == .organize || change.run != nil, change.kind == .rebuild))
            }
        }
        guard current == result else { return }
        for step in staged where step.before != step.after {
            if let run = step.run, let i = items.lastIndex(where: { $0.run == run }), i == items.count - 1 {
                items[i].after = step.after
                continue
            }
            items.append(NotesSnapshot(id: nextID, at: at, before: step.before, after: step.after, run: step.run, rebuild: step.rebuild))
            nextID += 1
        }
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
    }

    /// What restoring a snapshot does to the notes as they are now.
    public enum Restore: Equatable, Sendable {
        /// The text to put back (the user's later edits are kept in it).
        case text(String)
        /// Later edits cannot be re-applied: the notes would be replaced by this text, after a confirmation.
        case replace(String)
    }

    /// The notes with `snapshot` put back. Edits made since the reorganize are kept when they sit in the part of the
    /// text it left alone (before its first change or after its last one); otherwise they would be lost.
    public static func restore(_ snapshot: NotesSnapshot, now current: String) -> Restore {
        if current == snapshot.after { return .text(snapshot.before) }
        let before = Array(snapshot.before.utf16), after = Array(snapshot.after.utf16)
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        guard let later = NotesDocument.diff(snapshot.after, current, kind: .user) else { return .text(snapshot.before) }
        var mapped = later
        if NSMaxRange(later.range) <= prefix {
            // Before the reorganized stretch: the same place in the earlier text.
        } else if later.range.location >= after.count - suffix {
            mapped.range.location += before.count - after.count
        } else {
            return .replace(snapshot.before)
        }
        guard NSMaxRange(mapped.range) <= before.count else { return .replace(snapshot.before) }
        return .text(mapped.applied(to: snapshot.before))
    }

    /// The words before and after as a diff, with the unchanged text around the changes trimmed to a little context.
    public static func diff(_ snapshot: NotesSnapshot, context: Int = 8) -> [WordDiff.Segment]? {
        let a = WordDiff.words(snapshot.before), b = WordDiff.words(snapshot.after)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let middleA = a[prefix..<(a.count - suffix)].joined(separator: " ")
        let middleB = b[prefix..<(b.count - suffix)].joined(separator: " ")
        guard let middle = WordDiff.segments(raw: middleA, cleaned: middleB) else { return nil }
        var out: [WordDiff.Segment] = []
        if prefix > 0 {
            let lead = a[max(0, prefix - context)..<prefix].joined(separator: " ")
            out.append(WordDiff.Segment(.same, (prefix > context ? "… " : "") + lead))
        }
        out += middle
        if suffix > 0 {
            let tail = a[(a.count - suffix)..<min(a.count, a.count - suffix + context)].joined(separator: " ")
            out.append(WordDiff.Segment(.same, tail + (suffix > context ? " …" : "")))
        }
        return out
    }
}
