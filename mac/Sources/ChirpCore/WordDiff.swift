import Foundation

/// A word-level comparison of the raw transcript and the cleaned text, for the HUD's brief "what changed" highlight.
/// Pure and bounded, so it is unit-tested and never costs noticeable time.
public enum WordDiff {
    public enum Kind: Sendable, Equatable {
        /// Present in both, spelled the same.
        case same
        /// In the raw text only: shown struck through, fading out.
        case removed
        /// In the cleaned text only (a replacement, or a word clean-up added).
        case added
        /// The same word with different case or punctuation: shown gently tinted.
        case changed
    }

    public struct Segment: Sendable, Equatable {
        public var kind: Kind
        public var text: String
        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Above this many word pairs the diff is skipped (the HUD just crossfades).
    public static let maxPairs = 90_000

    /// Segments in reading order: the cleaned text with the removed raw words inline. Nil when there is nothing
    /// to show (identical text) or the texts are too long to compare cheaply.
    public static func segments(raw: String, cleaned: String) -> [Segment]? {
        let a = words(raw), b = words(cleaned)
        guard a != b, !b.isEmpty, a.count * b.count <= maxPairs else { return nil }
        let out = walk(a.map(key), b.map(key)).map { step -> Segment in
            guard let j = step.cleaned else { return Segment(.removed, a[step.raw!]) }
            guard let i = step.raw else { return Segment(.added, b[j]) }
            return Segment(a[i] == b[j] ? .same : .changed, b[j])
        }
        // A replacement reads removed-then-added, whichever way the walk happened to break the tie.
        return reorderedReplacements(out)
    }

    /// For each cleaned word, the index of the raw word it matches (same word up to case and punctuation), or nil
    /// for a word the clean-up added. Nil when the texts are too long to compare cheaply.
    public static func alignment(raw: [String], cleaned: [String]) -> [Int?]? {
        let ka = raw.map(key), kb = cleaned.map(key)
        if ka == kb { return Array(cleaned.indices) }
        guard raw.count * cleaned.count <= maxPairs else { return nil }
        var out = [Int?](repeating: nil, count: cleaned.count)
        for step in walk(ka, kb) { if let j = step.cleaned { out[j] = step.raw } }
        return out
    }

    /// Splits text into words the way the diff and the alignment count them.
    public static func words(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// The longest-common-subsequence walk over normalised keys, in reading order: matched pairs, then words only in
    /// the cleaned text (`raw` nil) or only in the raw text (`cleaned` nil).
    private static func walk(_ ka: [String], _ kb: [String]) -> [(raw: Int?, cleaned: Int?)] {
        var table = [[Int]](repeating: [Int](repeating: 0, count: kb.count + 1), count: ka.count + 1)
        for i in stride(from: ka.count - 1, through: 0, by: -1) {
            for j in stride(from: kb.count - 1, through: 0, by: -1) {
                table[i][j] = ka[i] == kb[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [(raw: Int?, cleaned: Int?)] = []
        var i = 0, j = 0
        while i < ka.count || j < kb.count {
            if i < ka.count, j < kb.count, ka[i] == kb[j] {
                out.append((i, j)); i += 1; j += 1
            } else if j < kb.count, i == ka.count || table[i][j + 1] >= table[i + 1][j] {
                out.append((nil, j)); j += 1
            } else {
                out.append((i, nil)); i += 1
            }
        }
        return out
    }

    /// The text the segments spell once the removed words are gone.
    public static func cleanedText(_ segments: [Segment]) -> String {
        segments.filter { $0.kind != .removed }.map(\.text).joined(separator: " ")
    }

    private static func reorderedReplacements(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        var run: [Segment] = []
        func flush() {
            out += run.filter { $0.kind == .removed } + run.filter { $0.kind == .added }
            run.removeAll()
        }
        for s in segments {
            if s.kind == .removed || s.kind == .added { run.append(s) } else { flush(); out.append(s) }
        }
        flush()
        return out
    }

    /// Case and punctuation are not part of a word's identity ("Three," matches "three").
    private static func key(_ w: String) -> String {
        let letters = w.lowercased().filter { $0.isLetter || $0.isNumber }
        return letters.isEmpty ? w : String(letters)
    }
}
