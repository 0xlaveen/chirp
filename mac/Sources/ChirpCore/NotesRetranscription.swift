import Foundation

/// One segment's new transcript from a re-transcribe run (#287), staged in memory until the whole run applies.
public struct NotesRetranscribedSegment: Equatable, Sendable {
    /// The document segment (= the kept clip's id).
    public var segment: Int
    public var raw: String
    public var text: String
    public var corrected: Bool
    public var keptOriginal: Bool
    /// The raw words' timings, seconds from the clip's first sample; nil from an engine without them.
    public var words: [WordTiming]?
    /// Session seconds of the clip's first sample (`NotesAudioReference.offset`; on the Mac it includes a hard cut's
    /// overlap).
    public var clipOffset: TimeInterval
    /// `ready.engine` of the socket that produced it.
    public var engine: String?

    public init(segment: Int, raw: String, text: String, corrected: Bool = false, keptOriginal: Bool = false,
                words: [WordTiming]? = nil, clipOffset: TimeInterval = 0, engine: String? = nil) {
        self.segment = segment
        self.raw = raw
        self.text = text
        self.corrected = corrected
        self.keptOriginal = keptOriginal
        self.words = words
        self.clipOffset = clipOffset
        self.engine = engine
    }
}

/// The transcript a re-transcribe replaced (one version is kept): Undo and Restore previous transcript swap it back.
/// Stored with the note, so it survives a relaunch; search and export never read it.
public struct NotesPreviousTranscript: Codable, Equatable, Sendable {
    public var at: Date
    /// The engine the replaced text came from: one name, `NotesSpeechModel.mixed`, or nil when unknown.
    public var engine: String?
    public var segments: [Saved]

    /// A segment's words as they were. Turns keep their people: only their text is swapped back.
    public struct Saved: Codable, Equatable, Sendable {
        public var id: Int
        public var raw: String
        public var text: String
        public var corrected: Bool
        public var keptOriginal: Bool
        public var failure: String?
        public var turns: [SpeakerTurn]?
        public var engine: String?

        init(_ s: NotesSegment) {
            id = s.id; raw = s.raw; text = s.text; corrected = s.corrected; keptOriginal = s.keptOriginal
            failure = s.failure; turns = s.turns; engine = s.engine
        }
    }
}

/// Speech model names for people: the server's `engine` (`parakeet-mlx:tdt-0.6b-v2`) as "Parakeet v2 (MLX)".
public enum NotesSpeechModel {
    /// The note's segments came from more than one model.
    public static let mixed = "mixed"

    public static func displayName(_ engine: String?) -> String {
        guard let engine, !engine.isEmpty else { return "unknown" }
        if engine == mixed { return "mixed models" }
        let lower = engine.lowercased()
        if lower.hasPrefix("sensevoice") { return "SenseVoice Small" }
        if lower.hasPrefix("parakeet") {
            let version = lower.contains("v3") ? "v3" : "v2"
            let runtime = lower.hasPrefix("parakeet-onnx") ? "ONNX" : "MLX"
            return "Parakeet \(version) (\(runtime))"
        }
        return engine
    }

    /// One engine for all of `engines`, `mixed` when they differ, nil when none is known.
    static func summary(_ engines: [String?]) -> String? {
        let known = Set(engines.compactMap { $0 })
        guard !known.isEmpty else { return nil }
        if known.count == 1, !engines.contains(where: { $0 == nil }) { return known.first }
        return mixed
    }
}

extension NotesDocument {
    /// The speech model the transcript came from ("Transcribed with …"): one engine, `mixed`, or nil when unknown
    /// (notes recorded before segments kept it).
    public var transcribedWith: String? {
        NotesSpeechModel.summary(segments.filter { !$0.isGap && !$0.text.isEmpty }.map(\.engine))
    }

    /// Replaces the words of each re-transcribed segment in one change, keeping its timing (`id`, `offset`, `end`,
    /// `pauseBefore`) and who spoke when: the new words are re-attributed to the existing turns (#287 §2.5), so names,
    /// merges and reassignments still apply. A gap that now has text loses its failure. The words it replaced become
    /// `previousTranscript` (one version; a later run replaces it). Returns how many segments changed.
    @discardableResult
    public mutating func applyRetranscription(_ results: [NotesRetranscribedSegment], at date: Date = Date()) -> Int {
        let valid = results.filter {
            segments.indices.contains($0.segment) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !valid.isEmpty else { return 0 }
        let saved = valid.map { NotesPreviousTranscript.Saved(segments[$0.segment]) }
        for r in valid {
            var s = segments[r.segment]
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = r.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            s.raw = raw.isEmpty ? text : raw
            s.text = text
            s.corrected = r.corrected
            s.keptOriginal = r.keptOriginal
            s.failure = nil
            s.engine = r.engine
            if let turns = s.turns, !turns.isEmpty {
                s.turns = NotesRetranscription.reattribute(turns, words: r.words, raw: s.raw, text: s.text,
                                                           clipOffset: r.clipOffset, end: s.end)
            }
            segments[r.segment] = s
        }
        previousTranscript = NotesPreviousTranscript(at: date, engine: NotesSpeechModel.summary(saved.map(\.engine)), segments: saved)
        for r in valid { relabelled(r.segment) }
        return valid.count
    }

    /// Undo and Restore previous transcript: the kept version and the current words swap places, so doing it twice
    /// round-trips exactly. Turns keep the people they have now (a reassignment made since stays). False when there
    /// is nothing to restore.
    @discardableResult
    public mutating func restorePreviousTranscript(at date: Date = Date()) -> Bool {
        guard let previous = previousTranscript else { return false }
        let kept = previous.segments.filter { segments.indices.contains($0.id) }
        guard !kept.isEmpty else { previousTranscript = nil; return false }
        let current = kept.map { NotesPreviousTranscript.Saved(segments[$0.id]) }
        for old in kept {
            var s = segments[old.id]
            s.raw = old.raw
            s.text = old.text
            s.corrected = old.corrected
            s.keptOriginal = old.keptOriginal
            s.failure = old.failure
            s.engine = old.engine
            if let now = s.turns, let then = old.turns, now.count == then.count {
                s.turns = zip(now, then).map { now, then in
                    var t = now
                    t.text = then.text
                    t.raw = then.raw
                    t.approximate = then.approximate
                    t.keptOriginal = then.keptOriginal
                    return t
                }
            } else {
                s.turns = old.turns
            }
            segments[old.id] = s
        }
        previousTranscript = NotesPreviousTranscript(at: date, engine: NotesSpeechModel.summary(current.map(\.engine)),
                                                     segments: current)
        for old in kept { relabelled(old.id) }
        return true
    }

    /// Debug hook for the re-transcribe tests (#287 §6): every spoken segment and turn reads `text` (raw too), so what a
    /// re-transcribe brings back is obviously from the audio. Timing, people and gaps stay. Never called by the app.
    public mutating func overwriteTranscript(_ text: String) {
        for i in segments.indices where !segments[i].isGap {
            segments[i].text = text
            segments[i].raw = text
            segments[i].turns = segments[i].turns?.map { var t = $0; t.text = text; t.raw = text; return t }
            relabelled(i)
        }
    }

    /// Rebuild the notes: the body becomes `text` (structured again from the new transcript) as one `.rebuild` change,
    /// settled, with the window past every segment so live structuring never sends them again. The user title is
    /// untouched. Nil when nothing changed.
    @discardableResult
    public mutating func replaceBody(with body: String, fallbackBlocks blocks: [String]) -> NotesTextChange? {
        let change = NotesDocument.diff(text, body, kind: .rebuild)
        text = body
        fallbackBlocks = blocks
        tailStart = count
        resetWindow(to: segments.count)
        if let change { changed(inserted: change.replacement.utf16.count) }
        return change
    }
}

/// The pure rules of a re-transcribe, unit-tested without a server.
public enum NotesRetranscription {
    /// The new words of one segment over its existing turns (#287 §2.5). The turn array keeps its length, order,
    /// people and `manual` marks; only `text` and `raw` change (and `approximate` without word timings).
    ///
    /// With word timings, each raw word goes to the turn whose span (its `start` to the next turn's, the last to the
    /// segment's `end`) holds the word's midpoint, else the nearest one; the corrected text follows its raw words by
    /// alignment. Without them, one turn takes everything; several split the words in proportion to their duration,
    /// at word boundaries, and are marked approximate. A turn that receives no words keeps an empty text.
    public static func reattribute(_ turns: [SpeakerTurn], words: [WordTiming]?, raw: String, text: String,
                                   clipOffset: TimeInterval, end: TimeInterval?) -> [SpeakerTurn] {
        guard !turns.isEmpty else { return turns }
        var out = turns
        if turns.count == 1 {
            out[0].text = text
            out[0].raw = raw
            out[0].keptOriginal = false
            return out
        }
        let rawWords = WordDiff.words(raw)
        let timed = (words ?? []).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !timed.isEmpty, timed.count == rawWords.count else {
            return proportional(turns, raw: raw, text: text, end: end)
        }
        let spans = turns.indices.map { i -> (start: TimeInterval, end: TimeInterval) in
            let stop = i + 1 < turns.count ? turns[i + 1].start : max(end ?? turns[i].start, turns[i].start)
            return (turns[i].start, stop)
        }
        // Each raw word's turn, never earlier than the word before it (turns are in time order).
        var owner: [Int] = []
        for w in timed {
            let mid = clipOffset + (w.start + max(w.end, w.start)) / 2
            var best = spans.firstIndex { mid >= $0.start && mid < $0.end }
            if best == nil {
                best = spans.indices.min { distance(mid, spans[$0]) < distance(mid, spans[$1]) }
            }
            owner.append(max(best ?? 0, owner.last ?? 0))
        }
        var raws = [[String]](repeating: [], count: turns.count)
        for (i, word) in rawWords.enumerated() { raws[owner[i]].append(word) }
        var texts = [[String]](repeating: [], count: turns.count)
        let cleaned = WordDiff.words(text)
        if let alignment = WordDiff.alignment(raw: rawWords, cleaned: cleaned),
           Double(alignment.compactMap { $0 }.count) >= SpeakerAttribution.minAligned * Double(cleaned.count) {
            var current = owner.first ?? 0
            for (j, word) in cleaned.enumerated() {
                // A word clean-up added stays with the word before it; a reordered one never moves a turn back.
                if let i = alignment[j] { current = max(current, owner[i]) }
                texts[current].append(word)
            }
            for i in out.indices { out[i].keptOriginal = false }
        } else {
            // The clean-up rewrote too much to place: each turn shows its raw words.
            texts = raws
            for i in out.indices { out[i].keptOriginal = true }
        }
        for i in out.indices {
            out[i].raw = raws[i].joined(separator: " ")
            out[i].text = texts[i].joined(separator: " ")
        }
        return out
    }

    private static func distance(_ t: TimeInterval, _ span: (start: TimeInterval, end: TimeInterval)) -> TimeInterval {
        t < span.start ? span.start - t : max(0, t - span.end)
    }

    /// No word timings: the words go to the turns in proportion to each turn's duration, cut at word boundaries.
    static func proportional(_ turns: [SpeakerTurn], raw: String, text: String, end: TimeInterval?) -> [SpeakerTurn] {
        let last = turns[turns.count - 1].start
        let durations = turns.indices.map { i -> TimeInterval in
            let stop = i + 1 < turns.count ? turns[i + 1].start : max(end ?? last + 1, last + 1)
            return max(stop - turns[i].start, 0.01)
        }
        let total = durations.reduce(0, +)
        func split(_ words: [String]) -> [[String]] {
            var out: [[String]] = []
            var from = 0, share: TimeInterval = 0
            for (i, d) in durations.enumerated() {
                share += d
                let to = i == durations.count - 1 ? words.count : min(words.count, Int((Double(words.count) * share / total).rounded()))
                out.append(Array(words[from..<max(from, to)]))
                from = max(from, to)
            }
            return out
        }
        let texts = split(WordDiff.words(text)), raws = split(WordDiff.words(raw))
        var out = turns
        for i in out.indices {
            out[i].text = texts[i].joined(separator: " ")
            out[i].raw = raws[i].joined(separator: " ")
            out[i].approximate = true
            out[i].keptOriginal = false
        }
        return out
    }
}

/// Re-transcribe's "Also rebuild the notes" (#287 §2.6): the existing structuring passes over the whole new
/// transcript, window by window as live recording runs them (the same `maxWindowChars`, outline chaining, speaker
/// lines and fallback blocks), with `final` on the last. The caller replaces the body with the result in one
/// `.rebuild` change.
public enum NotesRebuild {
    public struct Result: Equatable, Sendable {
        public var text: String
        public var fallbackBlocks: [String]
        /// Passes tried, and how many structured their window (the rest became fallback blocks).
        public var windows: Int
        public var structured: Int
    }

    /// Nil when every window failed (the body is left alone: "Couldn’t rebuild the notes") or the task was cancelled.
    public static func run(_ source: NotesDocument, structure: @escaping NotesRecorder.Structure) async -> Result? {
        var d = NotesDocument(startedAt: source.startedAt)
        d.roster = source.roster
        var windows = 0, structured = 0
        func pass(final: Bool) async {
            guard let request = d.nextStructureRequest(final: final) else { d.freezeOverflow(); return }
            windows += 1
            let response = (try? await structure(request)) ?? NotesStructureResponse(markdown: nil, structured: false, error: "http")
            if response.structured, response.markdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { structured += 1 }
            d.apply(response, for: request)
        }
        for segment in source.segments {
            if Task.isCancelled { return nil }
            d.append(segment)
            if d.windowChars() >= NotesDocument.freezeChars { await pass(final: false) }
        }
        if Task.isCancelled { return nil }
        await pass(final: true)
        d.freezeAll(structuring: true)
        guard structured > 0, !Task.isCancelled else { return nil }
        return Result(text: d.text, fallbackBlocks: d.fallbackBlocks, windows: windows, structured: structured)
    }
}
