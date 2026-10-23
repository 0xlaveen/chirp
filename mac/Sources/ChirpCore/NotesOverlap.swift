import Foundation

/// The newest audio routed to Live Notes' sockets, at most `capacity` bytes of 16 kHz PCM16 (whole frames, so up to
/// one frame more): what a hard cut sends again at the start of the next segment. Not thread-safe: the router holds
/// it under its lock. Memory only.
struct PCMRing {
    let capacity: Int
    private var frames: [Data] = []
    private var head = 0
    private(set) var bytes = 0

    init(seconds: TimeInterval) { capacity = Int(seconds * PCMConverter.sampleRate) * 2 }

    mutating func append(_ frame: Data) {
        guard !frame.isEmpty else { return }
        frames.append(frame)
        bytes += frame.count
        while head < frames.count - 1, bytes - frames[head].count >= capacity {
            bytes -= frames[head].count
            head += 1
        }
        if head >= 64 {
            frames.removeFirst(head)
            head = 0
        }
    }

    var contents: ArraySlice<Data> { frames[head...] }
    var seconds: TimeInterval { Double(bytes) / (PCMConverter.sampleRate * 2) }

    mutating func removeAll() {
        frames.removeAll()
        head = 0
        bytes = 0
    }
}

/// The seams between Live Notes segments. At a hard cut the last `NotesSegmenter.overlap` of audio goes to both
/// sockets, so each final is trimmed to its own side of the overlap's middle by each word's midpoint (a word heard
/// on both sockets lands once, whole), and then the new one loses a first word or bigram that still repeats the
/// previous segment's last (the only text rule without timings). Pure, so every rule is unit-tested.
public enum NotesJoin {
    /// At most this much of the previous segment's final goes along as clean-up context (`stop.context`).
    public static let contextChars = 200
    /// A pause at least this long between two segments starts a new transcript paragraph.
    public static let paragraphPause: TimeInterval = 2

    public struct Final: Equatable, Sendable {
        public var raw: String
        public var text: String
        public var words: [WordTiming]?

        public init(raw: String, text: String, words: [WordTiming]? = nil) {
            self.raw = raw
            self.text = text
            self.words = words
        }
    }

    /// `final` (of a segment `duration` seconds long) without the words that belong to its neighbours: the first
    /// `leading` seconds were also heard by the previous segment, the last `trailing` by the next one. Needs word
    /// timings; without them, or with no overlap, it is returned as is.
    public static func trim(_ final: Final, leading: TimeInterval, trailing: TimeInterval, duration: TimeInterval) -> Final {
        guard leading > 0 || trailing > 0, let words = final.words, !words.isEmpty,
              words.count == tokens(final.raw).count else { return final }
        let from = leading > 0 ? leading / 2 : -.infinity
        let to = trailing > 0 ? duration - trailing / 2 : .infinity
        let keep = words.indices.filter { i in
            let mid = (words[i].start + max(words[i].end, words[i].start)) / 2
            return mid >= from && mid < to
        }
        guard keep.count < words.count else { return final }
        guard let first = keep.first, let last = keep.last else { return Final(raw: "", text: "", words: []) }
        let kept = Array(words[first...last])
        let dropped = (head: words[..<first].map(\.text), tail: words[(last + 1)...].map(\.text))
        let text = dropText(final.text, head: dropped.head, tail: dropped.tail, kept: kept.map(\.text))
        return Final(raw: kept.map(\.text).joined(separator: " "), text: text, words: kept)
    }

    /// The new segment's first two words when they repeat the previous segment's last two, else its first word when
    /// it repeats the last one (case and punctuation aside). Only after a hard cut, after `trim` when there are word
    /// timings (the two decodes of the overlap can disagree on a word's time).
    public static func dedupe(_ final: Final, after previous: String) -> Final {
        let before = tokens(previous).suffix(2).map(normalized)
        let raw = tokens(final.raw)
        let words = raw.map(normalized)
        var count = 0
        if before.count == 2, words.count > 2, Array(words.prefix(2)) == before { count = 2 }
        else if let last = before.last, words.count > 1, words.first == last, !last.isEmpty { count = 1 }
        guard count > 0 else { return final }
        let kept = Array(raw.dropFirst(count))
        let text = dropText(final.text, head: Array(raw.prefix(count)), tail: [], kept: kept)
        return Final(raw: kept.joined(separator: " "), text: text, words: final.words.map { Array($0.dropFirst(count)) })
    }

    /// The end of the previous final as clean-up context: its last `contextChars` characters, from a word start.
    public static func context(_ previous: String) -> String? {
        let trimmed = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > contextChars else { return trimmed }
        let tail = trimmed.suffix(contextChars)
        guard let space = tail.firstIndex(where: \.isWhitespace) else { return String(tail) }
        return String(tail[space...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: text

    static func tokens(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    static func normalized(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" })
    }

    /// The corrected text with the dropped raw words taken off its start and end. Clean-up only deletes words, so the
    /// text is a subsequence of the raw words: a text word goes only when every way of placing it in the raw words puts
    /// it among the dropped ones (so "the the export" trimmed to "the export" keeps "The export."). A text that is not
    /// a subsequence (another style rewrote it) loses only the dropped words it starts or ends with, in order.
    static func dropText(_ text: String, head: [String], tail: [String], kept: [String]) -> String {
        let t = tokens(text)
        let words = t.map(normalized)
        let raw = (head + kept + tail).map(normalized)
        let keptEnd = head.count + kept.count
        var earliest: [Int] = [], latest: [Int] = []
        var i = 0
        for w in words {
            while i < raw.count, raw[i] != w { i += 1 }
            guard i < raw.count else { break }
            earliest.append(i)
            i += 1
        }
        i = raw.count - 1
        for w in words.reversed() {
            while i >= 0, raw[i] != w { i -= 1 }
            guard i >= 0 else { break }
            latest.insert(i, at: 0)
            i -= 1
        }
        var from = 0, to = t.count
        if earliest.count == t.count, latest.count == t.count {
            while from < t.count, latest[from] < head.count { from += 1 }
            while to > from, earliest[to - 1] >= keptEnd { to -= 1 }
        } else {
            var h = head.map(normalized)[...]
            while from < t.count, let w = h.first { h = h.dropFirst(); if words[from] == w { from += 1 } }
            var r = tail.map(normalized)[...]
            while to > from, let w = r.last { r = r.dropLast(); if words[to - 1] == w { to -= 1 } }
        }
        return t[from..<to].joined(separator: " ")
    }
}
