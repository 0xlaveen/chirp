import Foundation

/// Whole-document Organize for long notes: past `maxReorganizeChars` the document is walked in groups of whole
/// sections, oldest first, one reorganize call each (sent with the other groups' headings as the outline), then one
/// merge pass for a heading that ended up in two groups. Each step is version-checked like a single reorganize.
extension NotesDocument {
    /// Organize walks the whole document in steps (it is longer than one reorganize takes).
    public var organizesInSteps: Bool { text.unicodeScalars.count > Self.maxReorganizeChars }

    /// The groups Organize would walk from UTF-16 `cursor` on, as it stands: for the step count.
    public func organizeGroupCount(from cursor: Int = 0) -> Int {
        var count = 0, at = cursor
        while let r = organizeStep(from: at, final: false) {
            count += 1
            at = NSMaxRange(r.range)
        }
        return count
    }

    /// The step for the first group at or after UTF-16 `cursor`: the most whole sections from there within
    /// `maxReorganizeChars`. A section longer than that alone is skipped, and so is a group with too little to
    /// reorganize. Nil when nothing is left.
    public func organizeStep(from cursor: Int, final: Bool) -> NotesReorganizeRequest? {
        let ns = text as NSString
        let sections = NotesMarkdown.sections(text).filter { NSMaxRange($0.range) > cursor }
        var i = sections.startIndex
        while i < sections.endIndex {
            let start = max(sections[i].range.location, cursor)
            var end = start, chars = 0
            var j = i
            while j < sections.endIndex {
                let r = sections[j].range
                let size = ns.substring(with: NSRange(location: max(r.location, cursor), length: NSMaxRange(r) - max(r.location, cursor)))
                    .unicodeScalars.count
                guard chars + size <= Self.maxReorganizeChars else { break }
                chars += size
                end = NSMaxRange(r)
                j += 1
            }
            if j == i {
                i += 1                                      // one section over the limit: left as it is
                continue
            }
            let range = NSRange(location: start, length: end - start)
            let notes = ns.substring(with: range)
            guard notes.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minReorganizeChars else {
                i = j
                continue
            }
            let outside = NotesMarkdown.headings(ns.substring(to: range.location)) + NotesMarkdown.headings(ns.substring(from: end))
            return NotesReorganizeRequest(notes: notes, outline: Self.capOutline(outside), final: final, version: version,
                                          range: range, documentID: id)
        }
        return nil
    }

    /// The merge pass: the sections under the first heading that appears more than once (case and emphasis aside),
    /// sent together (as many as fit, at least two) with every other heading as the outline. Nil when no heading
    /// repeats or two of them do not fit.
    public func organizeMergeRequest(final: Bool) -> NotesReorganizeRequest? {
        let ns = text as NSString
        let sections = NotesMarkdown.sections(text)
        let keys = sections.map { $0.heading.map(Self.headingKey) }
        var counts: [String: Int] = [:]
        for case let key? in keys { counts[key, default: 0] += 1 }
        guard let key = keys.first(where: { $0.map { counts[$0, default: 0] > 1 } ?? false }) ?? nil else { return nil }
        let same = sections.indices.filter { keys[$0] == key }
        var picked: [NSRange] = [], chars = 0
        for i in same {
            let body = ns.substring(with: sections[i].range).trimmingCharacters(in: .whitespacesAndNewlines)
            let size = body.unicodeScalars.count + (picked.isEmpty ? 0 : 2)
            guard chars + size <= Self.maxReorganizeChars else { break }
            chars += size
            picked.append(sections[i].range)
        }
        guard picked.count >= 2 else { return nil }
        let notes = picked.map { ns.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
        let others = sections.indices.filter { !picked.contains(sections[$0].range) }.compactMap { sections[$0].heading }
        var request = NotesReorganizeRequest(notes: notes, outline: Self.capOutline(others), final: final, version: version,
                                             range: picked[0], documentID: id)
        request.merged = Array(picked.dropFirst())
        return request
    }
}
