import Foundation

/// The server's speaker turns (`final.speakers`) cover the final it sent. At an overlapped cut the recorder keeps less
/// of that final (the words the neighbouring segment heard are trimmed), so the turns are cut down to what it kept.
public enum ServerTurns {
    /// `turns` restricted to `text` (and `raw`), the final as the segment kept it; `original` is the final as the server
    /// sent it. Unchanged when nothing was trimmed. Nil when the kept text cannot be found in the turns (then the
    /// segment stays unlabelled rather than mislabelled).
    public static func restrict(_ turns: [ServerTurn], text: String, raw: String,
                                original: (text: String, raw: String)) -> [ServerTurn]? {
        let covered = turns.contains { $0.keptOriginal } ? raw : text
        let sent = turns.contains { $0.keptOriginal } ? original.raw : original.text
        if covered == sent, text == original.text, raw == original.raw { return turns }
        let kept = tokens(covered)
        guard !kept.isEmpty else { return nil }
        let words = turns.map { tokens($0.text) }
        guard let range = find(kept, in: words.flatMap { $0 }) else { return nil }
        let raws = turns.map { tokens($0.raw) }
        let rawRange = raw == original.raw ? nil : find(tokens(raw), in: raws.flatMap { $0 })
        var out: [ServerTurn] = []
        var offset = 0, rawOffset = 0
        for (i, turn) in turns.enumerated() {
            let mine = offset..<(offset + words[i].count)
            let rawMine = rawOffset..<(rawOffset + raws[i].count)
            offset = mine.upperBound
            rawOffset = rawMine.upperBound
            let keep = mine.clamped(to: range)
            guard !keep.isEmpty else { continue }
            var t = turn
            t.text = words[i][(keep.lowerBound - mine.lowerBound)..<(keep.upperBound - mine.lowerBound)].joined(separator: " ")
            if let rawRange {
                let rawKeep = rawMine.clamped(to: rawRange)
                t.raw = rawKeep.isEmpty ? t.text
                    : raws[i][(rawKeep.lowerBound - rawMine.lowerBound)..<(rawKeep.upperBound - rawMine.lowerBound)].joined(separator: " ")
            }
            out.append(t)
        }
        return out.isEmpty ? nil : out
    }

    static func tokens(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// Where `needle` sits in `hay` as a run of identical words.
    private static func find(_ needle: [String], in hay: [String]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        for start in 0...(hay.count - needle.count) where Array(hay[start..<(start + needle.count)]) == needle {
            return start..<(start + needle.count)
        }
        return nil
    }
}
