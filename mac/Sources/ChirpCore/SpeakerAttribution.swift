import Foundation

/// Gives each word of a Notes segment a speaker from the diarizer's timeline, then splits the segment into turns.
/// Labels are computed on the raw words (they carry the timings) and carried onto the corrected text by a word
/// alignment. Pure, so every rule is unit-tested without a model.
public enum SpeakerAttribution {
    /// A word with no overlapping span takes a span this close.
    public static let nearestWithin: TimeInterval = 1.0
    /// A run shorter than this many words *and* `minTurnSeconds`, between two runs of one person, is absorbed…
    public static let minTurnWords = 2
    public static let minTurnSeconds: TimeInterval = 0.5
    /// …unless the diarizer really heard that other voice for at least this long (a backchannel is kept).
    public static let keepDetected: TimeInterval = 0.3
    /// Under this share of corrected words aligned to raw ones, the clean-up rewrote too much: keep the raw turns.
    public static let minAligned = 0.6

    /// A turn before the roster numbers it: the diarizer slot speaking.
    public struct Turn: Equatable, Sendable {
        public var slot: Int
        public var start: TimeInterval
        public var text: String
        public var raw: String
        public var approximate = false
        public var keptOriginal = false

        public init(slot: Int, start: TimeInterval, text: String, raw: String? = nil, approximate: Bool = false,
                    keptOriginal: Bool = false) {
            self.slot = slot
            self.start = start
            self.text = text
            self.raw = raw ?? text
            self.approximate = approximate
            self.keptOriginal = keptOriginal
        }
    }

    /// The turns of one segment: `words` are its raw word timings (seconds from the segment's first sample, nil from
    /// an engine without them), `offset…end` its audio in document seconds, `spans` the diarizer's spans and
    /// `previousSlot` the slot of the document's last labelled word. Nil when no speaker can be told at all.
    public static func turns(words: [WordTiming]?, raw: String, text: String, offset: TimeInterval, end: TimeInterval,
                             spans: [SpeakerSpan], previousSlot: Int? = nil) -> [Turn]? {
        let words = (words ?? []).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !words.isEmpty else {
            guard let slot = dominant(in: offset..<max(end, offset), spans: spans) ?? previousSlot else { return nil }
            return [Turn(slot: slot, start: offset, text: text, raw: raw, approximate: true)]
        }
        let times = words.map { (start: offset + $0.start, end: offset + max($0.end, $0.start)) }
        guard var slots = assign(times, spans: spans, previousSlot: previousSlot) else { return nil }
        smooth(&slots, times: times, spans: spans)
        return project(words: words.map(\.text), times: times, slots: slots, text: text)
    }

    // MARK: words

    /// Each word's slot (overlap, else nearest within 1 s, else the previous word's, else the next word's), and
    /// whether the diarizer heard that slot over the word for at least `keepDetected`.
    static func assign(_ times: [(start: TimeInterval, end: TimeInterval)], spans: [SpeakerSpan],
                       previousSlot: Int?) -> [Int]? {
        var slots: [Int?] = times.map { slot(for: $0, spans: spans) }
        // Words the diarizer missed (overlap, a backchannel it never caught) inherit the nearest labelled neighbour.
        var last: Int?
        for i in slots.indices { if let s = slots[i] { last = s } else if let last { slots[i] = last } }
        var next: Int?
        for i in slots.indices.reversed() { if let s = slots[i] { next = s } else if let next { slots[i] = next } }
        if slots.allSatisfy({ $0 == nil }), let previousSlot { return slots.map { _ in previousSlot } }
        let resolved = slots.compactMap { $0 }
        return resolved.count == slots.count ? resolved : nil
    }

    static func slot(for word: (start: TimeInterval, end: TimeInterval), spans: [SpeakerSpan]) -> Int? {
        var best: (slot: Int, overlap: TimeInterval)?
        for s in spans {
            let overlap = min(word.end, s.end) - max(word.start, s.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (s.slot, overlap) }
        }
        if let best { return best.slot }
        var nearest: (slot: Int, distance: TimeInterval)?
        for s in spans {
            let distance = max(s.start - word.end, word.start - s.end, 0)
            if distance <= nearestWithin, distance < (nearest?.distance ?? .infinity) { nearest = (s.slot, distance) }
        }
        return nearest?.slot
    }

    /// The slot with the most speech in `range`, else the closest span within `nearestWithin`.
    static func dominant(in range: Range<TimeInterval>, spans: [SpeakerSpan]) -> Int? {
        var totals: [Int: TimeInterval] = [:]
        for s in spans {
            let overlap = min(range.upperBound, s.end) - max(range.lowerBound, s.start)
            if overlap > 0 { totals[s.slot, default: 0] += overlap }
        }
        if let top = totals.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { return top.key }
        return slot(for: (range.lowerBound, range.upperBound), spans: spans)
    }

    /// Absorbs a short run (under `minTurnWords` words and `minTurnSeconds`) between two runs of one person, unless
    /// the diarizer heard its voice there for `keepDetected` or longer.
    static func smooth(_ slots: inout [Int], times: [(start: TimeInterval, end: TimeInterval)], spans: [SpeakerSpan]) {
        let runs = runs(slots)
        guard runs.count >= 3 else { return }
        for r in 1..<(runs.count - 1) where slots[runs[r - 1].lowerBound] == slots[runs[r + 1].lowerBound] {
            let run = runs[r]
            let slot = slots[run.lowerBound]
            let start = times[run.lowerBound].start, end = times[run.upperBound - 1].end
            guard run.count < minTurnWords, end - start < minTurnSeconds else { continue }
            let heard = spans.filter { $0.slot == slot && $0.end > start - 0.05 && $0.start < end + 0.05 }
                .contains { $0.duration >= keepDetected }
            if heard { continue }
            for i in run { slots[i] = slots[runs[r - 1].lowerBound] }
        }
    }

    static func runs(_ slots: [Int]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for i in 1...slots.count where i == slots.count || slots[i] != slots[start] {
            out.append(start..<i)
            start = i
        }
        return slots.isEmpty ? [] : out
    }

    // MARK: corrected text

    /// The turns over the corrected `text`: each corrected word takes the slot of the raw word it aligns to, and an
    /// added word the slot of the word before it. A heavy rewrite keeps one raw-text turn per raw run.
    static func project(words raw: [String], times: [(start: TimeInterval, end: TimeInterval)], slots: [Int],
                        text: String) -> [Turn] {
        let rawRuns = runs(slots)
        let rawTurns = rawRuns.map { r in
            let raw = raw[r].joined(separator: " ")
            return Turn(slot: slots[r.lowerBound], start: times[r.lowerBound].start, text: raw, raw: raw)
        }
        let cleaned = WordDiff.words(text)
        guard !cleaned.isEmpty else { return rawTurns }
        if rawRuns.count == 1 {
            // One speaker: the corrected text as it is (whatever the clean-up did to it).
            return [Turn(slot: slots[0], start: times[0].start, text: text, raw: rawTurns[0].raw)]
        }
        guard let alignment = WordDiff.alignment(raw: raw, cleaned: cleaned),
              Double(alignment.compactMap { $0 }.count) >= minAligned * Double(cleaned.count) else {
            return rawTurns.map { var t = $0; t.keptOriginal = true; return t }
        }
        // Each corrected word's raw run: its aligned word's run, else the previous corrected word's (else the first).
        let runOf: [Int] = rawRuns.enumerated().flatMap { r, run in run.map { _ in r } }
        var groups: [(run: Int, words: [String])] = []
        for (j, word) in cleaned.enumerated() {
            let run = alignment[j].map { runOf[$0] } ?? groups.last?.run ?? alignment.compactMap({ $0 }).first.map { runOf[$0] } ?? 0
            // A word aligned to an earlier run than the one before it (a reordering) stays in the current turn.
            if let last = groups.last, run <= last.run { groups[groups.count - 1].words.append(word) } else { groups.append((run, [word])) }
        }
        // Each raw run's text goes with the last group at or before it (a run the clean-up dropped joins the one before).
        var raws = [[String]](repeating: [], count: groups.count)
        for (r, turn) in rawTurns.enumerated() {
            raws[groups.lastIndex { $0.run <= r } ?? 0].append(turn.raw)
        }
        var turns: [Turn] = []
        for (g, group) in groups.enumerated() {
            let text = group.words.joined(separator: " "), raw = raws[g].joined(separator: " ")
            let slot = rawTurns[group.run].slot
            if let last = turns.last, last.slot == slot {
                turns[turns.count - 1].text += " " + text
                turns[turns.count - 1].raw += raw.isEmpty ? "" : " " + raw
            } else {
                turns.append(Turn(slot: slot, start: rawTurns[group.run].start, text: text, raw: raw))
            }
        }
        return turns
    }
}
