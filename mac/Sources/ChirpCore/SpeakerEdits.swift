import Foundation

/// Live Notes speaker fix-ups (issue #18 M2): rename a person, merge two, separate a merge, reassign a turn, and
/// carry a rename into the notes. Session-only like the roster: nothing here is logged or stored anywhere else.

/// A transcript turn: segment `segment`'s `turns[index]` (a `TranscriptParagraph.Part` id "segment.index").
public struct SpeakerTurnRef: Hashable, Sendable {
    public var segment: Int
    public var index: Int

    public init(segment: Int, index: Int) {
        self.segment = segment
        self.index = index
    }

    /// `"3.1"` → segment 3, turn 1; nil for a whole (unlabelled) segment.
    public init?(partID: String) {
        let parts = partID.split(separator: ".")
        guard parts.count == 2, let s = Int(parts[0]), let i = Int(parts[1]) else { return nil }
        self.init(segment: s, index: i)
    }
}

/// "Replace in notes" as applied: the changes (in order), what puts the text back, and the version it is valid at.
public struct SpeakerNameReplacement: Equatable, Sendable {
    public var old: String
    public var new: String
    public var changes: [NotesTextChange]
    /// The inverse changes, in the order to apply them.
    public var inverse: [NotesTextChange]
    public var fallbackBlocks: [String]
    /// `version` right after the replace: Undo applies only while nothing else changed the notes.
    public var version: Int

    /// Several replaces made one after another as one: their changes in order, and an inverse that undoes the last
    /// first, from the text before the first. Nil when there were none.
    public static func combined(_ list: [SpeakerNameReplacement]) -> SpeakerNameReplacement? {
        guard let first = list.first, let last = list.last else { return nil }
        return SpeakerNameReplacement(old: first.old, new: first.new, changes: list.flatMap(\.changes),
                                      inverse: list.reversed().flatMap(\.inverse), fallbackBlocks: first.fallbackBlocks,
                                      version: last.version)
    }
}

extension NotesDocument {
    /// The turns of a transcript paragraph (its labelled parts).
    public static func turnRefs(_ paragraph: TranscriptParagraph) -> [SpeakerTurnRef] {
        paragraph.parts.compactMap { SpeakerTurnRef(partID: $0.id) }
    }

    /// `person` and everyone merged into them become `target`: past turns resolve to it, and the diarizer slots that
    /// spoke as `person` feed `target` from now on. `separateSpeaker` undoes it.
    public mutating func mergeSpeaker(_ person: Int, into target: Int) {
        guard roster.resolve(person) != roster.resolve(target) else { return }
        roster.merge(person, into: target)
        isDirtyForSpeakers()
    }

    public mutating func separateSpeaker(_ person: Int) {
        guard roster.person(id: person)?.mergedInto != nil else { return }
        roster.separate(person)
        isDirtyForSpeakers()
    }

    /// "This turn is ▸": the turns go to `person` (nil: a new person) and are marked manual, so later labels never
    /// change them. Returns the person they went to.
    @discardableResult
    public mutating func reassignTurns(_ refs: [SpeakerTurnRef], to person: Int?) -> Int? {
        let valid = refs.filter { segments.indices.contains($0.segment) && segments[$0.segment].turns?.indices.contains($0.index) == true }
        guard !valid.isEmpty else { return nil }
        let target = person.map(roster.resolve) ?? roster.addPerson()
        for ref in valid {
            segments[ref.segment].turns?[ref.index].person = target
            segments[ref.segment].turns?[ref.index].manual = true
        }
        for segment in Set(valid.map(\.segment)).sorted() { relabelled(segment) }
        return target
    }

    /// Seconds of labelled speech per person (after merges), from turn starts: a turn runs until the next one or
    /// its segment's end.
    public var speechSeconds: [Int: TimeInterval] {
        var out: [Int: TimeInterval] = [:]
        for s in segments {
            guard let turns = s.turns, !turns.isEmpty else { continue }
            let end = s.end ?? turns.last!.start
            for (i, t) in turns.enumerated() {
                let stop = i + 1 < turns.count ? turns[i + 1].start : end
                out[roster.resolve(t.person), default: 0] += max(stop - t.start, 0)
            }
        }
        return out
    }

    /// Names and merges change the export (not the notes text); the transcript rows rebuild from the roster.
    private mutating func isDirtyForSpeakers() { isDirty = true }

    /// A session name for a person (nil or blank: "Person N" again). Later passes and exports use it.
    public mutating func renameSpeaker(_ id: Int, to name: String?) {
        roster.rename(id, to: name)
        isDirtyForSpeakers()
    }

    // MARK: replace in notes

    /// Where `name` occurs in `text` as a whole word (never `Person 20` for `Person 2`), UTF-16 ranges.
    public static func nameRanges(_ name: String, in text: String) -> [NSRange] {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: needle, range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound else { break }
            let before = r.location > 0 ? ns.substring(with: ns.rangeOfComposedCharacterSequence(at: r.location - 1)) : ""
            let after = r.upperBound < ns.length ? ns.substring(with: ns.rangeOfComposedCharacterSequence(at: r.upperBound)) : ""
            if !isWordPart(before), !isWordPart(after) { out.append(r) }
            from = r.upperBound
        }
        return out
    }

    private static func isWordPart(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
    }

    /// How many times the notes say `name` as a whole word (the rename banner's offer).
    public func nameCount(_ name: String) -> Int { Self.nameRanges(name, in: text).count }

    /// Replaces every whole-word `old` in the notes with `new`. The AI tail stays the AI's (a replace inside it is
    /// not a user claim), and fallback blocks keep matching so Organize still finds them. Nil when there is none.
    public mutating func replaceSpeakerName(_ old: String, with new: String) -> SpeakerNameReplacement? {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        let ranges = Self.nameRanges(old, in: text).filter { $0.upperBound <= tailStart || $0.location >= tailStart }
        guard !new.isEmpty, !ranges.isEmpty else { return nil }
        let blocks = fallbackBlocks
        let ns = text as NSString, length = new.utf16.count
        // Last first, so each range is still valid in the text before it. The inverse ranges are in the text after
        // all of them (each earlier one shifted it), undone last first too.
        let changes = ranges.reversed().map { NotesTextChange(range: $0, replacement: new, kind: .rename) }
        let inverse = ranges.enumerated().map { j, r in
            NotesTextChange(range: NSRange(location: r.location + j * (length - r.length), length: length),
                            replacement: ns.substring(with: r), kind: .rename)
        }.reversed()
        for change in changes { applyKeepingTail(change) }
        fallbackBlocks = fallbackBlocks.map { block in
            Self.nameRanges(old, in: block).reversed().reduce(block) { ($0 as NSString).replacingCharacters(in: $1, with: new) }
        }
        changed(inserted: 0)
        return SpeakerNameReplacement(old: old, new: new, changes: changes, inverse: Array(inverse),
                                      fallbackBlocks: blocks, version: version)
    }

    /// Undoes `replacement` while the notes are exactly as it left them; returns the changes it made (nil: they
    /// changed since, so it is not undone).
    public mutating func revert(_ replacement: SpeakerNameReplacement) -> [NotesTextChange]? {
        guard version == replacement.version else { return nil }
        for change in replacement.inverse { applyKeepingTail(change) }
        fallbackBlocks = replacement.fallbackBlocks
        changed(inserted: 0)
        return replacement.inverse
    }

    /// A text change that never claims the tail: before it, the tail moves; inside it, it stays the AI's.
    private mutating func applyKeepingTail(_ change: NotesTextChange) {
        text = change.applied(to: text)
        if change.range.location < tailStart { tailStart += change.replacement.utf16.count - change.range.length }
    }
}
