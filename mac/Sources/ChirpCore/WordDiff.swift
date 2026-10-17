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
        let ka = a.map(key), kb = b.map(key)
        // Longest common subsequence over the normalised keys.
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = ka[i] == kb[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [Segment] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, ka[i] == kb[j] {
                out.append(Segment(a[i] == b[j] ? .same : .changed, b[j]))
                i += 1; j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                out.append(Segment(.added, b[j])); j += 1
            } else {
                out.append(Segment(.removed, a[i])); i += 1
            }
        }
        // A replacement reads removed-then-added, whichever way the walk happened to break the tie.
        return reorderedReplacements(out)
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

    private static func words(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// Case and punctuation are not part of a word's identity ("Three," matches "three").
    private static func key(_ w: String) -> String {
        let letters = w.lowercased().filter { $0.isLetter || $0.isNumber }
        return letters.isEmpty ? w : String(letters)
    }
}
