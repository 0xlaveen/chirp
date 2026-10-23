import Foundation

/// Live Notes speaker labels (issue #18): who spoke when, as Person 1, Person 2… Diarization runs on this Mac in the
/// `ChirpSpeakers` target; this file holds the dependency-free contract and the session roster. Nothing here is logged
/// or sent anywhere except as transcript text in the existing structuring request, and no timeline or audio is stored;
/// the roster (names, merges, labelled turns) reaches disk only in the Live Notes recovery journal and a Save….

/// One stretch of speech by one diarizer slot, in document seconds (the clock of `NotesSegment.offset`).
public struct SpeakerSpan: Equatable, Sendable {
    /// The diarizer's output slot: arbitrary and never shown (the roster numbers people).
    public var slot: Int
    public var start: TimeInterval
    public var end: TimeInterval

    public init(slot: Int, start: TimeInterval, end: TimeInterval) {
        self.slot = slot
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end - start }
}

/// What the diarizer knows so far, in document seconds.
public struct SpeakerTimeline: Equatable, Sendable {
    /// Closed spans no later audio changes.
    public var spans: [SpeakerSpan]
    /// Every span up to here is settled: audio before it has its final speaker decisions.
    public var finalizedThrough: TimeInterval
    /// Open spans (a voice still talking at the frontier) and the preview past it; replaced on every update.
    public var tentative: [SpeakerSpan]

    /// Closed spans kept behind the settled frontier: a label never looks further back (a timed-out segment is
    /// labelled again within seconds), so the timeline, and each snapshot of it, stays small over hours.
    public static let retained: TimeInterval = 600

        public init(spans: [SpeakerSpan] = [], finalizedThrough: TimeInterval = 0, tentative: [SpeakerSpan] = []) {
        self.spans = spans
        self.finalizedThrough = finalizedThrough
        self.tentative = tentative
    }

    /// The spans to label with: the closed ones, plus the part of each open span the diarizer already settled
    /// (someone mid-sentence at the frontier). `includeTentative` adds the unsettled preview too (a label timeout).
    public func labellingSpans(includeTentative: Bool = false) -> [SpeakerSpan] {
        let open = tentative.compactMap { s -> SpeakerSpan? in
            if includeTentative { return s }
            guard s.start < finalizedThrough else { return nil }
            return SpeakerSpan(slot: s.slot, start: s.start, end: min(s.end, finalizedThrough))
        }
        return spans + open
    }

    /// `labellingSpans` limited to those near `range` (a segment's audio, give or take the attribution's reach).
    public func labellingSpans(includeTentative: Bool = false, near range: ClosedRange<TimeInterval>) -> [SpeakerSpan] {
        let lo = range.lowerBound - Self.reach, hi = range.upperBound + Self.reach
        return labellingSpans(includeTentative: includeTentative).filter { $0.end > lo && $0.start < hi }
    }

    /// How far from a segment a span can still matter: the nearest-span rule and the smoothing look this far.
    static let reach: TimeInterval = 2

    /// Drops closed spans that ended more than `retained` before the frontier.
    public mutating func prune() {
        let horizon = finalizedThrough - Self.retained
        if let first = spans.first, first.end < horizon { spans.removeAll { $0.end < horizon } }
    }
}

/// A local speaker diarizer fed the Notes capture frames. Implementations keep all audio, state and embeddings in
/// memory, never touch the network after their one-time model download, and never block the caller.
public protocol SpeakerDiarizing: AnyObject, Sendable {
    /// One capture frame (16 kHz mono PCM16) that starts at `documentTime`; any thread, returns at once. A jump in
    /// `documentTime` (a stopped interval, dropped audio) is the implementation's to map, so spans stay in document time.
    func feed(_ pcm16: Data, at documentTime: TimeInterval)
    /// Stop: let the tail settle (pad silence and drain), keeping the session so a later Record continues it.
    func flush() async
    var snapshot: SpeakerTimeline { get }
    /// New: forget every speaker.
    func reset()
}

/// One person's stretch of a segment's text.
public struct SpeakerTurn: Equatable, Sendable, Codable {
    /// The roster id (Person N).
    public var person: Int
    /// Document seconds of the turn's first word.
    public var start: TimeInterval
    /// The corrected text, or the raw text when it fell back.
    public var text: String
    public var raw: String
    /// No word timings: the whole segment went to the person who spoke most of it.
    public var approximate = false
    /// M2: the user reassigned it; never changed automatically afterwards.
    public var manual = false
    /// The clean-up rewrote too much to place the labels, so this turn shows its raw text.
    public var keptOriginal = false

    public init(person: Int, start: TimeInterval, text: String, raw: String? = nil, approximate: Bool = false,
                manual: Bool = false, keptOriginal: Bool = false) {
        self.person = person
        self.start = start
        self.text = text
        self.raw = raw ?? text
        self.approximate = approximate
        self.manual = manual
        self.keptOriginal = keptOriginal
    }
}

/// The people of one Notes document, numbered by first appearance: the first diarizer slot that speaks becomes
/// Person 1. Session-only names and merges live here too (memory only, gone with the document).
public struct SpeakerRoster: Equatable, Sendable, Codable {
    /// Colours cycle through this many (the palette lives in the UI).
    public static let paletteSize = 8

    public struct Person: Equatable, Sendable, Codable {
        public var id: Int
        public var name: String?
        /// Set once this person was merged into another.
        public var mergedInto: Int?
    }

    public private(set) var people: [Person] = []
    /// Diarizer slot → person id. A merge points the slot at the target, so future audio follows it.
    private var slots: [Int: Int] = [:]

    public init() {}

    /// The person a slot speaks as, numbering a new one on first sight.
    public mutating func person(forSlot slot: Int) -> Int { resolve(id(forSlot: slot)) }

    /// The id a slot was numbered as (before merges): what a turn stores, so undoing a merge gives it back.
    public mutating func id(forSlot slot: Int) -> Int {
        if let id = slots[slot] { return id }
        let id = addPerson()
        slots[slot] = id
        return id
    }

    /// A person no slot speaks as yet ("This turn is ▸ New person").
    public mutating func addPerson() -> Int {
        people.append(Person(id: people.count + 1))
        return people.count
    }

    /// The person a slot already maps to, if any.
    public func existingPerson(forSlot slot: Int) -> Int? { slots[slot].map(resolve) }

    /// Some slot that speaks as `id` (after merges), for continuity across segments.
    public func slot(for id: Int) -> Int? {
        let target = resolve(id)
        return slots.filter { resolve($0.value) == target }.map(\.key).min()
    }

    /// Follows merges to the person who stands for `id` now.
    public func resolve(_ id: Int) -> Int {
        var current = id
        var seen: Set<Int> = []
        while let next = person(id: current)?.mergedInto, seen.insert(current).inserted { current = next }
        return current
    }

    public func person(id: Int) -> Person? { people.indices.contains(id - 1) ? people[id - 1] : nil }

    /// The one name used everywhere: the transcript, the export and the structuring transcript.
    public func displayName(_ id: Int) -> String {
        let target = resolve(id)
        if let name = person(id: target)?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return "Person \(target)"
    }

    /// A stable colour slot for `id` (after merges).
    public func colorIndex(_ id: Int) -> Int { (resolve(id) - 1) % Self.paletteSize }

    /// A session name; nil or blank goes back to "Person N".
    public mutating func rename(_ id: Int, to name: String?) {
        let target = resolve(id)
        guard people.indices.contains(target - 1) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        people[target - 1].name = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// `id` becomes `target`: past turns resolve to it, and its slots feed it from now on (they still point at `id`,
    /// which resolves to `target`, so `separate` undoes it).
    public mutating func merge(_ id: Int, into target: Int) {
        let from = resolve(id), to = resolve(target)
        guard from != to, people.indices.contains(from - 1), people.indices.contains(to - 1) else { return }
        people[from - 1].mergedInto = to
    }

    /// Undoes `merge` of `id`: its turns and slots are its own again (people merged into it stay with it).
    public mutating func separate(_ id: Int) {
        guard people.indices.contains(id - 1) else { return }
        people[id - 1].mergedInto = nil
    }

    /// The people merged straight into `id`, for "Separate ▸".
    public func merged(into id: Int) -> [Int] { people.filter { $0.mergedInto == id }.map(\.id) }

    /// People still standing (not merged away), in order.
    public var active: [Int] { people.filter { $0.mergedInto == nil }.map(\.id) }

    /// A recovered session has a new diarizer whose slots mean other voices: forget the slot map, keep the people.
    public mutating func forgetSlots() { slots = [:] }

    /// People still standing (not merged away).
    public var activeCount: Int { people.filter { $0.mergedInto == nil }.count }
}

/// A scripted diarizer for tests (no model): it "hears" the spans it was given once the audio fed passes their end,
/// `lag` seconds behind live, like the real one.
public final class FakeDiarizer: SpeakerDiarizing, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [SpeakerSpan]
    private let lag: TimeInterval
    private var fedThrough: TimeInterval = 0
    private var flushed: TimeInterval = 0
    public private(set) var resets = 0
    public private(set) var flushes = 0
    public private(set) var framesFed = 0

    public init(script: [SpeakerSpan], lag: TimeInterval = 1) {
        self.script = script
        self.lag = lag
    }

    public func feed(_ pcm16: Data, at documentTime: TimeInterval) {
        lock.withLock {
            framesFed += 1
            fedThrough = max(fedThrough, documentTime + Double(pcm16.count / 2) / 16_000)
        }
    }

    /// Flushes wait here until `releaseFlush()` while this is set (tests of Stop's ordering).
    public var holdFlush = false
    private var heldFlush: CheckedContinuation<Void, Never>?

    public func flush() async {
        let hold = lock.withLock { holdFlush }
        if hold { await withCheckedContinuation { c in lock.withLock { heldFlush = c } } }
        lock.withLock { flushes += 1; flushed = fedThrough }
    }

    public func releaseFlush() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { heldFlush = nil }; holdFlush = false; return heldFlush }
        c?.resume()
    }

    public var flushWaiting: Bool { lock.withLock { heldFlush != nil } }

    public var snapshot: SpeakerTimeline {
        lock.withLock {
            let frontier = max(flushed, fedThrough - lag, 0)
            let closed = script.filter { $0.end <= frontier }
            let open = script.filter { $0.start < fedThrough && $0.end > frontier }
                .map { SpeakerSpan(slot: $0.slot, start: $0.start, end: min($0.end, fedThrough)) }
            return SpeakerTimeline(spans: closed, finalizedThrough: frontier, tentative: open)
        }
    }

    public func reset() { lock.withLock { resets += 1; fedThrough = 0; flushed = 0 } }

    /// Replace what it will "hear" (tests that script a second recording).
    public func setScript(_ spans: [SpeakerSpan]) { lock.withLock { script = spans } }
}

/// The only speaker-label log line: counts and timings, never a label, a name or text.
public enum SpeakerLog {
    public static func labels(speakers: Int, lag: TimeInterval, tentative: Bool) -> String {
        "notes labels speakers=\(speakers) lag_ms=\(Int((lag * 1000).rounded())) tentative=\(tentative)"
    }
}
