import Foundation

/// One paragraph of the transcript: a gap, or the words of one person (or unlabelled speech) across segments that
/// follow each other without a gap, a speaker change or a pause of `NotesJoin.paragraphPause`. The window, the export
/// and the jump from a section all read the same paragraphs.
public struct TranscriptParagraph: Equatable, Sendable, Identifiable {
    /// A segment (or one speaker turn of a labelled one) inside the paragraph: its own timestamp for hover.
    public struct Part: Equatable, Sendable, Identifiable {
        /// `"3"` for a whole segment, `"3.1"` for a turn.
        public var id: String
        public var segment: Int
        public var offset: TimeInterval
        public var text: String
        public var raw: String
        public var keptOriginal: Bool

        public func text(_ raw: Bool) -> String { raw ? self.raw : text }
    }

    public var parts: [Part]
    /// The roster id (before merges); nil for unlabelled speech and gaps.
    public var person: Int?
    /// No word timings placed this person's words: the chip is dotted.
    public var approximate = false
    /// Set for a gap: why its audio was not transcribed.
    public var failure: String?

    public var id: String { parts[0].id }
    public var offset: TimeInterval { parts[0].offset }
    public var segments: ClosedRange<Int> { parts[0].segment...parts[parts.count - 1].segment }

    public func text(raw: Bool = false) -> String { parts.map { raw ? $0.raw : $0.text }.joined(separator: " ") }
}

extension NotesDocument {
    /// Paragraphs from segment `start` on, appended to `paragraphs` (the last one may grow). Built incrementally by
    /// the window: only segments that changed are walked again.
    public func extendParagraphs(_ paragraphs: inout [TranscriptParagraph], from start: Int) {
        guard start < segments.count else { return }
        for s in segments[start...] {
            if let failure = s.failure {
                paragraphs.append(TranscriptParagraph(parts: [Self.part(s, id: "\(s.id)", offset: s.offset, text: "", raw: "")],
                                                      failure: failure))
                continue
            }
            let units: [(part: TranscriptParagraph.Part, person: Int?, approximate: Bool)]
            if let turns = s.turns, !turns.isEmpty {
                units = turns.enumerated().map { i, t in
                    (Self.part(s, id: "\(s.id).\(i)", offset: t.start, text: t.text, raw: t.raw, kept: t.keptOriginal),
                     roster.resolve(t.person), t.approximate)
                }
            } else {
                units = [(Self.part(s, id: "\(s.id)", offset: s.offset, text: s.text, raw: s.raw), nil, false)]
            }
            for (i, unit) in units.enumerated() {
                if i == 0, var last = paragraphs.last, last.failure == nil, last.parts.last?.segment == s.id - 1,
                   last.person.map(roster.resolve) == unit.person, let pause = s.pauseBefore, pause < NotesJoin.paragraphPause {
                    last.parts.append(unit.part)
                    last.approximate = last.approximate || unit.approximate
                    paragraphs[paragraphs.count - 1] = last
                } else {
                    paragraphs.append(TranscriptParagraph(parts: [unit.part], person: unit.person, approximate: unit.approximate))
                }
            }
        }
    }

    public var transcriptParagraphs: [TranscriptParagraph] {
        var p: [TranscriptParagraph] = []
        extendParagraphs(&p, from: 0)
        return p
    }

    private static func part(_ s: NotesSegment, id: String, offset: TimeInterval, text: String, raw: String,
                             kept: Bool = false) -> TranscriptParagraph.Part {
        TranscriptParagraph.Part(id: id, segment: s.id, offset: offset, text: text, raw: raw, keptOriginal: s.keptOriginal || kept)
    }

    /// The paragraph that holds the segment at `offset` (the last one starting at or before it).
    public func paragraphID(at offset: TimeInterval, in paragraphs: [TranscriptParagraph]) -> String? {
        var lo = 0, hi = paragraphs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if paragraphs[mid].offset <= offset + 0.001 { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? paragraphs[lo - 1].id : paragraphs.first?.id
    }
}
