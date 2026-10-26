import Foundation

/// The Name speakers sheet's model side (issue #247 item 3a): who can be named, what the sheet's Done asks for, and the
/// names it offers while typing. Names are the note's own and are saved with it; nothing here is logged.

/// One person's change from the sheet: a name (blank goes back to "Person N"), or "same person as" another.
public struct SpeakerNaming: Equatable, Sendable {
    public var person: Int
    public var name: String?
    public var mergeInto: Int?
    public var remember: Bool

    public init(person: Int, name: String? = nil, mergeInto: Int? = nil, remember: Bool = true) {
        self.person = person
        self.name = name
        self.mergeInto = mergeInto
        self.remember = remember
    }
}

extension NotesDocument {
    /// The people who spoke in this note, as the sheet lists them: still standing (not merged away), with a turn, and
    /// not the microphone's "You". In order of first appearance.
    public var namableSpeakers: [Int] {
        let spoke = Set(segments.flatMap { $0.turns ?? [] }.map { roster.resolve($0.person) })
        return roster.active.filter { spoke.contains($0) && roster.person(id: $0)?.local != true }
    }

    /// The people of `namableSpeakers` who are still "Person N".
    public var unnamedSpeakers: [Int] {
        namableSpeakers.filter { roster.person(id: $0)?.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
    }

    /// The names people in this note were given, for the other notes' autocomplete (a note's own words, never a voice).
    public var namedSpeakers: [String] {
        var seen = Set<String>(), out: [String] = []
        for id in roster.active {
            guard let name = roster.person(id: id)?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  seen.insert(name.lowercased()).inserted else { continue }
            out.append(name)
        }
        return out
    }
}

/// The names the sheet offers under a field: saved voices first, then names used in recent notes.
public enum SpeakerNameSuggestions {
    public static let limit = 4

    /// `saved` and `recent` in the order to offer them. `taking` are names other rows already hold; `query` is what the
    /// field holds (a name or a word of one that starts with it matches; an exact match is not offered back).
    public static func names(saved: [String], recent: [String], taking: [String] = [], matching query: String,
                             limit: Int = SpeakerNameSuggestions.limit) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let taken = Set(taking.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var seen = Set<String>(), out: [String] = []
        for name in saved + recent {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines), key = n.lowercased()
            guard !n.isEmpty, key != q, !taken.contains(key), !seen.contains(key) else { continue }
            if !q.isEmpty, !key.split(separator: " ").contains(where: { $0.hasPrefix(q) }), !key.hasPrefix(q) { continue }
            seen.insert(key)
            out.append(n)
            if out.count == limit { break }
        }
        return out
    }
}
