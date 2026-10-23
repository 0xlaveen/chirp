import Foundation

public enum NotesRecorderState: Equatable, Sendable {
    case idle, starting, recording, stopping, stopped
    case error(String)

    /// The microphone is (or is about to be) open.
    public var isCapturing: Bool { self == .starting || self == .recording }
    /// Starting, recording or finishing: Record/Stop is busy and the document cannot be replaced.
    public var isActive: Bool { isCapturing || self == .stopping }
}

/// Why the structuring pass does not run.
public enum StructuringOff: Equatable, Sendable {
    /// The user turned "Structure notes" off.
    case disabled
    /// The server has correction off (health, or a 409 `notes_off`).
    case correctionOff
    /// The server predates `POST /v1/notes/structure` (no `notes_structure` in health, or a 404).
    case unsupported
    /// The server's health is not known yet, so nothing says where structuring would send text: fail closed.
    case waiting
}

public enum StructuringStatus: Equatable, Sendable {
    case off(StructuringOff)
    case idle, running
    /// The last pass failed with this code (`timeout`, `rejected`, `http`, `busy`…); the next segment retries.
    case failed(String)

    public var isOff: Bool { if case .off = self { true } else { false } }

    /// Whether structuring can run against a server with this health, with the user's toggle at `enabled`. Unknown
    /// health never allows it: where the text would go (this Mac or another host) is not known yet.
    public static func availability(health: Health?, enabled: Bool) -> StructuringStatus {
        guard let health else { return .off(.waiting) }
        if health.correction == "off" { return .off(.correctionOff) }
        if health.notesStructure != true { return .off(.unsupported) }
        return enabled ? .idle : .off(.disabled)
    }
}

/// The Reorganize button's and the auto pass's state.
public enum ReorganizeStatus: Equatable, Sendable {
    /// Structuring is off, or the server has no reorganize endpoint (`.unsupported`).
    case unavailable(StructuringOff)
    case idle, running
    /// A reorganize changed the notes at this time (the recorder's clock).
    case applied(at: TimeInterval)
    /// The last pass failed with this code (`timeout`, `rejected`, `http`, `busy`…); auto retries later.
    case failed(String)
    /// Organize is at this step (structuring the pending window and fallback blocks, then reorganizing).
    case organizing(step: Int, of: Int)
    /// Organize finished; `failed` sections (or the reorganize) kept as they were, the first one for `reason`.
    case organized(failed: Int, reason: String?)
    /// The notes changed while a manual reorganize ran, so its result was discarded.
    case conflict
    /// The last section alone is over `NotesDocument.maxReorganizeChars`.
    case tooLong
}

extension ReorganizeStatus {
    /// A reorganize or an Organize is running.
    public var isRunning: Bool {
        switch self {
        case .running, .organizing: true
        default: false
        }
    }
}

/// What a pass did, for the controller's counts-only log.
public enum NotesPassEvent: Equatable, Sendable {
    /// A rejected window was split: how deep, into how many parts, and how many stayed raw.
    case split(windowChars: Int, depth: Int, parts: Int, fallbacks: Int)
    /// Organize ran this many steps; `failed` sections kept as they were.
    case organize(steps: Int, failed: Int, conflict: Bool)
}

/// Routes capture frames to the current segment's socket and runs the segmenter, on the audio thread. The swap at a
/// cut is atomic under the lock, so every frame lands on exactly one socket, in order, except at a hard cut: the
/// last `NotesSegmenter.overlap` of audio the old socket got is sent again as the start of the new one.
final class NotesFrameRouter: @unchecked Sendable {
    /// What a swap did: the old target, the document time of the switch, how much audio (seconds) was sent again to
    /// the new target, and the quiet before the old segment's first speech (across the join before it).
    struct Swap {
        var old: StreamSession?
        var offset: TimeInterval
        var overlap: TimeInterval = 0
        var pause: TimeInterval = 0
    }

    private let lock = NSLock()
    private var target: StreamSession?
    private var segmenter = NotesSegmenter()
    private var cutRequested = false
    /// The requested cut is a hard one: the next swap overlaps.
    private var overlapNext = false
    private var recent = PCMRing(seconds: NotesSegmenter.overlap)
    /// Quiet in a row so far (it runs on across a swap), and what it was at the current segment's first speech.
    private var quietRun: TimeInterval = 0
    private var pauseAtStart: TimeInterval?
    /// Audio routed in this document, bytes of 16 kHz PCM16 (the segment offsets and the elapsed time).
    private var bytes = 0
    /// Speaker labels: the diarizer hears exactly the frames the sockets get, stamped on the same clock.
    private var speakers: SpeakerDiarizing?

    /// Sends the frame on; true when the segmenter wants a cut (asked once until the next swap).
    func route(_ frame: Data, level: Level) -> Bool {
        lock.withLock {
            guard let target else { return false }
            target.sendAudio(frame)
            recent.append(frame)
            speakers?.feed(frame, at: Double(bytes) / (PCMConverter.sampleRate * 2))
            bytes += frame.count
            let duration = Double(frame.count / 2) / PCMConverter.sampleRate
            if level.rms < NotesSegmenter.quietRMS {
                quietRun += duration
            } else {
                if pauseAtStart == nil { pauseAtStart = quietRun }
                quietRun = 0
            }
            guard !cutRequested, segmenter.feed(level, duration: duration) else { return false }
            cutRequested = true
            overlapNext = segmenter.hardCut
            return true
        }
    }

    /// Points capture at `next` (nil stops routing).
    func swap(to next: StreamSession?) -> Swap {
        lock.withLock {
            var result = Swap(old: target, offset: Double(bytes) / (PCMConverter.sampleRate * 2), pause: pauseAtStart ?? quietRun)
            target = next
            if overlapNext, let next, result.old != nil {
                for frame in recent.contents { next.sendAudio(frame) }
                result.overlap = recent.seconds
            }
            if next == nil {
                recent.removeAll()
                quietRun = 0
            }
            pauseAtStart = nil
            segmenter.reset()
            cutRequested = false
            overlapNext = false
            return result
        }
    }

    var seconds: TimeInterval { lock.withLock { Double(bytes) / (PCMConverter.sampleRate * 2) } }

    func setSpeakers(_ diarizer: SpeakerDiarizing?) { lock.withLock { speakers = diarizer } }

    func resetTime() { lock.withLock { bytes = 0 } }

    /// A recovered document continues its clock: new audio starts `seconds` in.
    func seed(seconds: TimeInterval) { lock.withLock { bytes = Int(max(0, seconds) * PCMConverter.sampleRate) * 2 } }
}

/// A Live Notes session: one long recording cut into ordinary `/v1/stream` utterances over rolling sockets, plus the
/// structuring passes that turn the transcript into Markdown. Every system edge (sockets, the structuring call, time)
/// is injected, so the logic runs in tests without a microphone or a network. Nothing here is logged or persisted.
@MainActor
public final class NotesRecorder {
    public typealias Structure = @Sendable (NotesStructureRequest) async throws -> NotesStructureResponse
    public typealias Reorganize = @Sendable (NotesReorganizeRequest) async throws -> NotesReorganizeResponse

    public enum PassKind: Equatable, Sendable { case append, reorganize }

    /// A pass starts at most this often (counted from the end of the last one).
    public static let minInterval: TimeInterval = 15
    /// How long a segment may take from `stop` to its final.
    public static let finalTimeout: TimeInterval = 25
    /// Segments in a row that may fail before recording stops.
    public static let maxSegmentFailures = 3
    /// A segment's speaker labels wait at most this long after its final for the diarizer to settle its audio;
    /// then they are attached from what it has (marked tentative).
    public static let labelTimeout: TimeInterval = 3
    /// How often a waiting label looks at the diarizer again.
    public static let labelPoll: Duration = .milliseconds(100)
    /// Auto-reorganize waits for this many inserted characters (user or AI) since the last one…
    public static let reorganizeEveryChars = 1200
    /// …this long since the last one ended…
    public static let reorganizeMinInterval: TimeInterval = 180
    /// …and this long without a keystroke.
    public static let typingIdle: TimeInterval = 15
    /// A rejected window is split at most this deep (halves, then quarters) before a part falls back to raw text.
    public static let maxSplitDepth = 2
    /// After a failed or discarded reorganize, auto waits this long instead of `reorganizeMinInterval`.
    public static let reorganizeRetryAfter: TimeInterval = 60
    /// A held append is applied after this long without a keystroke, even with the caret in the tail.
    public static let holdMax: TimeInterval = 10
    /// While recording, auto-reorganize starts only this soon after a segment commit: the free stretch before the
    /// next cut queues a clean-up that would preempt it.
    public static let reorganizeAfterCommit: TimeInterval = 5
    /// Stop skips its reorganize when one ended this recently on the same text.
    public static let stopReorganizeSkip: TimeInterval = 30
    /// A step of a whole-document Organize that a segment clean-up preempted is tried again this often, this long apart.
    public static let stepRetries = 2
    public static let stepRetryAfter: Duration = .seconds(2)

    public private(set) var state: NotesRecorderState = .idle { didSet { if state != oldValue { changed() } } }
    public private(set) var document = NotesDocument()
    public private(set) var structuring: StructuringStatus
    public private(set) var debugRetention = false
    /// AI changes to `document.text` the editor has not replayed yet, oldest first.
    public private(set) var pendingChanges: [NotesTextChange] = []
    /// The user's "Auto-reorganize" toggle.
    public private(set) var autoReorganize: Bool
    /// The kind of the pass in flight, if any.
    public private(set) var passKind: PassKind?
    /// The `start` options for the next segments (the controller refreshes them before each recording).
    public var options: StartOptions
    /// Shown as "Server unreachable at <host>" when the first segment cannot connect.
    public var serverHost: String
    public var onChange: (() -> Void)?
    /// Speaker labels for this document: the controller attaches its diarizer before Record (nil: labels off, and
    /// everything behaves as without the feature). Changing it applies from the next Record.
    public var speakers: SpeakerDiarizing?
    /// After each labelled segment (for the log and the bench): how long the labels took after the final, and
    /// whether they were attached before the diarizer settled. Never carries labels or text.
    public var onLabels: ((_ lag: TimeInterval, _ tentative: Bool) -> Void)?
    /// Splits and Organize runs, for the log (counts only).
    public var onPassEvent: ((NotesPassEvent) -> Void)?

    private let makeSession: (StartOptions) -> StreamSession
    private let structure: Structure
    private let reorganize: Reorganize
    private let now: () -> TimeInterval
    private let sleep: @Sendable (Duration) async -> Void
    private let router = NotesFrameRouter()

    private struct Segment {
        let session: StreamSession
        let offset: TimeInterval
        /// Where its audio ended (set at the cut that finalizes it).
        var end: TimeInterval?
        /// It follows the previous segment without a break (a cut, not Record), so its final may take that one's
        /// end as clean-up context and the transcript may join them.
        var joins = false
        /// Seconds of audio at its start that the previous segment also got, and at its end that the next one got.
        var leading: TimeInterval = 0
        var trailing: TimeInterval = 0
        /// Quiet before its first speech, across the join (set at its cut).
        var pause: TimeInterval?
        var partial = ""
        var correcting = false
        var task: Task<Void, Never>?
        var timeout: Task<Void, Never>?
    }

    private var segments: [Int: Segment] = [:]
    /// Finished segments waiting for an earlier one, so the transcript stays in order. nil: an empty final.
    private var results: [Int: NotesSegment?] = [:]
    private var nextSeq = 0
    private var nextCommit = 0
    private var current: Int?
    private var cutting = false
    private var failureStreak = 0
    private var sawReady = false
    /// The newest final (trimmed), for the next segment's context and dedupe.
    private var lastFinal: (seq: Int, text: String)?
    /// The server takes `stop.context` (health `notes_context`).
    private var contextSupported = false

    private var passTask: Task<Void, Never>?
    private var pending = false
    private var lastPassEnd: TimeInterval?
    private var timer: Task<Void, Never>?
    /// What the user and the server allow, independent of the running state.
    private var structuringAllowed: StructuringStatus
    private var epoch = 0

    /// The server has `POST /v1/notes/reorganize` (health), and it did not answer 404 this session.
    private var reorganizeSupported = false
    private var reorganizeEndpointMissing = false
    private var reorganizeState: ReorganizeStatus = .idle
    private var manualReorganize = false
    private var lastReorganizeEnd: TimeInterval?
    /// The last reorganize failed or was discarded: auto retries after `reorganizeRetryAfter`.
    private var reorganizeRetry = false
    private var lastKeystroke: TimeInterval?
    private var timerDeadline: TimeInterval?
    /// The editor's caret is in the tail (or IME is composing): appends wait.
    private var editorInTail = false
    private var editorComposing = false
    /// The newest append that arrived while the caret was in the tail.
    private var held: (request: NotesStructureRequest, response: NotesStructureResponse)?
    private var holdTask: Task<Void, Never>?
    /// When the last segment was committed to the document.
    private var lastCommit: TimeInterval?
    /// `document.version` when the last reorganize that ran (not preempted) ended.
    private var versionAtReorganizeEnd: Int?
    /// When Stop began, for the elapsed time on "Finishing…".
    private var stoppingSince: TimeInterval?
    private var waiters: [(check: () -> Bool, resume: CheckedContinuation<Void, Never>)] = []
    /// Numbers whole-document Organize runs, so the editor makes each one undo step.
    private var organizeRuns = 0

    /// A segment waiting for its speaker labels.
    private struct LabelJob {
        var segment = -1
        let offset: TimeInterval
        let end: TimeInterval
        let words: [WordTiming]?
        let raw: String
        let text: String
        let received: TimeInterval
    }
    /// Finals waiting to be committed, by sequence number; then the committed ones, in document order.
    private var labelJobs: [Int: LabelJob] = [:]
    private var labelQueue: [LabelJob] = []
    private var labelTask: Task<Void, Never>?
    /// Segments labelled at the timeout, kept to label again once the diarizer has settled their audio.
    private var tentativeJobs: [LabelJob] = []
    /// The diarizer the current recording feeds.
    private var activeSpeakers: SpeakerDiarizing?

    public init(makeSession: @escaping (StartOptions) -> StreamSession, structure: @escaping Structure,
                reorganize: @escaping Reorganize = { _ in throw NotesStructureError.unsupported(404) },
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                options: StartOptions, structuring: Bool, autoReorganize: Bool = true, health: Health? = nil, serverHost: String = "") {
        self.makeSession = makeSession
        self.structure = structure
        self.reorganize = reorganize
        self.autoReorganize = autoReorganize
        reorganizeSupported = health?.notesReorganize == true
        contextSupported = health?.notesContext == true
        self.now = now
        self.sleep = sleep
        self.options = options
        self.serverHost = serverHost
        structuringAllowed = .availability(health: health, enabled: structuring)
        self.structuring = structuringAllowed
    }

    /// Audio recorded into this document so far, seconds.
    public var elapsed: TimeInterval { router.seconds }

    /// Segments whose clean-up is running on the server.
    public var correctingCount: Int { segments.values.filter(\.correcting).count }

    /// Segments cut from capture whose final has not landed: still decoding or being cleaned up. A pass waits for
    /// them, so their clean-up never queues behind a structuring generation.
    public var finalizingCount: Int { segments.keys.filter { $0 != current }.count }

    public var passInFlight: Bool { passTask != nil }

    /// Committed segments whose speaker labels have not landed yet. A pass waits for them.
    public var labellingCount: Int { labelQueue.count }

    /// An append result is waiting for the caret to leave the tail.
    public var isHolding: Bool { held != nil }

    /// How long Stop has been finishing (nil when not stopping).
    public var stoppingElapsed: TimeInterval? { stoppingSince.map { now() - $0 } }

    /// What Reorganize can do now.
    public var reorganizeStatus: ReorganizeStatus {
        if case .off(let why) = structuring { return .unavailable(why) }
        if !reorganizeSupported { return .unavailable(.unsupported) }
        return reorganizeState
    }

    /// Hands the editor the AI changes to replay (and forgets them).
    public func takePendingChanges() -> [NotesTextChange] {
        defer { pendingChanges.removeAll() }
        return pendingChanges
    }

    private func publish(_ change: NotesTextChange?) {
        guard let change else { return }
        pendingChanges.append(change)
        // A newer change replaces the chip's reorganize as the thing Undo would revert.
        if case .applied = reorganizeState, change.kind != .reorganize { reorganizeState = .idle }
    }

    // MARK: configuration

    /// The user's "Structure notes" toggle or new server health. Turning it on schedules a pass for what is waiting.
    public func configureStructuring(enabled: Bool, health: Health?) {
        structuringAllowed = .availability(health: health, enabled: enabled)
        reorganizeSupported = health?.notesReorganize == true && !reorganizeEndpointMissing
        contextSupported = health?.notesContext == true
        if structuringAllowed.isOff {
            structuring = structuringAllowed
        } else if structuring.isOff {
            structuring = passTask == nil ? .idle : .running
            if state.isCapturing { schedule() }
        }
        changed()
    }

    // MARK: recording

    /// Starts recording into the document (a stopped document continues with a new window).
    public func start() {
        guard !state.isActive else { return }
        epoch += 1
        failureStreak = 0
        sawReady = false
        lastPassEnd = nil
        if lastReorganizeEnd == nil { lastReorganizeEnd = now() }
        if structuring.isOff, !structuringAllowed.isOff { structuring = .idle }
        state = .starting
        document.stampStart(Date())
        activeSpeakers = speakers
        router.setSpeakers(speakers)
        let seq = nextSeq
        nextSeq += 1
        let session = makeSession(options)
        let swap = router.swap(to: session)
        current = seq
        lastFinal = nil
        track(seq, session: session, offset: swap.offset)
        Task { await session.open() }
    }

    /// One capture frame, from the audio thread: it goes to the current segment's socket and through the segmenter.
    public nonisolated func handleFrame(_ data: Data, level: Level) {
        if router.route(data, level: level) {
            Task { @MainActor in await self.cut() }
        }
    }

    /// Stop: the last segment finalizes, one `final` pass runs, and the notes freeze.
    public func stop() async { await finish(error: nil) }

    /// Ends recording with an error (lost microphone, no signal…): finishes like Stop and keeps the content.
    public func fail(_ reason: String) async { await finish(error: reason) }

    /// Drops everything in flight at once (quit). The document is kept.
    public func cancel() {
        epoch += 1
        _ = router.swap(to: nil)
        for (_, s) in segments {
            s.task?.cancel()
            s.timeout?.cancel()
            Task { await s.session.cancel() }
        }
        segments.removeAll()
        results.removeAll()
        nextCommit = nextSeq
        current = nil
        passTask?.cancel()
        passTask = nil
        timer?.cancel()
        timer = nil
        pending = false
        manualReorganize = false
        dropHeld()
        if reorganizeState.isRunning { reorganizeState = .idle }
        passKind = nil
        dropLabels()
        document.livePartial = ""
        if state.isActive { state = document.isEmpty ? .idle : .stopped }
        if structuring == .running { structuring = structuringAllowed.isOff ? structuringAllowed : .idle }
        let waiting = waiters
        waiters.removeAll()
        for w in waiting { w.resume.resume() }
        changed()
    }

    /// New: an empty document (only while not recording).
    public func reset() {
        guard !state.isActive else { return }
        // A pass still running (a manual reorganize while stopped) belongs to the discarded document.
        epoch += 1
        passTask?.cancel()
        passTask = nil
        passKind = nil
        manualReorganize = false
        timer?.cancel()
        timer = nil
        timerDeadline = nil
        pending = false
        document = NotesDocument()
        router.resetTime()
        dropLabels()
        speakers?.reset()
        failureStreak = 0
        pendingChanges.removeAll()
        dropHeld()
        reorganizeState = .idle
        reorganizeRetry = false
        lastReorganizeEnd = nil
        versionAtReorganizeEnd = nil
        lastKeystroke = nil
        lastCommit = nil
        state = .idle
        if !structuringAllowed.isOff { structuring = .idle }
        changed()
    }

    /// Keep after a crash: `recovered` replaces the (empty) document as a stopped one, so Record continues into it with
    /// its clock at `elapsed`. The old diarizer slots are forgotten (a new diarizer's slots are other voices).
    public func restore(_ recovered: NotesDocument, elapsed: TimeInterval) {
        guard !state.isActive else { return }
        reset()
        document = recovered
        document.forgetSpeakerSlots()
        router.seed(seconds: elapsed)
        state = .stopped
        changed()
    }

    /// Save… wrote the document.
    public func markSaved() {
        document.markSaved()
        changed()
    }

    // MARK: segments

    /// The rolling handoff: open the next socket first, swap capture to it, then finalize the old one in the background.
    func cut() async {
        // One cut at a time (the segmenter and a roll after a dead socket can both ask): a second request is
        // already served by the swap in flight.
        guard state == .recording, !cutting else { return }
        cutting = true
        defer { cutting = false }
        let myEpoch = epoch
        let next = makeSession(options)
        await next.open()
        guard epoch == myEpoch, state == .recording else {
            await next.cancel()
            return
        }
        // The sequence number is taken at the swap, synchronously, so transcript order is capture order.
        let seq = nextSeq
        nextSeq += 1
        let swap = router.swap(to: next)
        let previous = current
        current = seq
        track(seq, session: next, offset: swap.offset - swap.overlap, joins: true, leading: swap.overlap)
        if let previous {
            segments[previous]?.end = swap.offset
            segments[previous]?.trailing = swap.overlap
            let joins = segments[previous]?.joins == true
            segments[previous]?.pause = joins ? swap.pause : nil
        }
        if let previous, let old = swap.old { finalize(previous, old) }
    }

    private func track(_ seq: Int, session: StreamSession, offset: TimeInterval, joins: Bool = false,
                       leading: TimeInterval = 0) {
        var segment = Segment(session: session, offset: offset, joins: joins, leading: leading)
        let myEpoch = epoch
        segment.task = Task {
            for await event in session.events {
                guard self.epoch == myEpoch else { return }
                if self.handle(event, seq: seq) { break }
            }
            guard self.epoch == myEpoch else { return }
            if self.segments[seq] != nil { self.segmentFailed(seq, reason: "connection closed") }
        }
        segments[seq] = segment
    }

    /// Ask the old segment for its final, with a deadline. With clean-up on the `live_notes` style and a server that
    /// takes it, the previous segment's end goes along as context (known by now: that final came while this one ran).
    private func finalize(_ seq: Int, _ session: StreamSession) {
        let context = contextSupported && options.correction && options.correctionProfile == CorrectionProfile.liveNotesID
            && segments[seq]?.joins == true && lastFinal?.seq == seq - 1 ? lastFinal.flatMap { NotesJoin.context($0.text) } : nil
        Task { await session.stop(context: context) }
        let sleep = self.sleep, myEpoch = epoch
        segments[seq]?.timeout = Task {
            await sleep(.seconds(Self.finalTimeout))
            guard !Task.isCancelled, self.epoch == myEpoch, self.segments[seq] != nil else { return }
            self.segmentFailed(seq, reason: "timed out")
        }
    }

    /// Returns true once the segment is done with.
    private func handle(_ event: StreamEvent, seq: Int) -> Bool {
        guard segments[seq] != nil else { return true }
        switch event {
        case .message(.ready(_, _, let debug)):
            debugRetention = debug
            sawReady = true
            if state == .starting { state = .recording }
            changed()
        case .message(.partial(_, let text, _, _)):
            segments[seq]?.partial = text
            updateLivePartial()
        case .message(.correcting(_, let raw, _, _)):
            segments[seq]?.partial = raw
            segments[seq]?.correcting = true
            updateLivePartial()
        case .message(.final(let f)):
            let joined = joinTrimmed(f, seq: seq)
            let text = joined.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = joined.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let offset = segments[seq]?.offset ?? 0
            let end = segments[seq]?.end ?? router.seconds
            let kept = options.correction && !f.corrected && f.correctionError != nil
            var segment = text.isEmpty ? nil : NotesSegment(id: seq, offset: offset, raw: raw.isEmpty ? text : raw, text: text,
                                                            corrected: f.corrected, keptOriginal: kept)
            segment?.end = end
            segment?.pauseBefore = segments[seq]?.pause
            if !text.isEmpty { lastFinal = (seq, text) }
            if let segment, activeSpeakers != nil {
                labelJobs[seq] = LabelJob(offset: offset, end: end, words: joined.words,
                                          raw: segment.raw, text: segment.text, received: now())
            }
            failureStreak = 0
            finish(seq, with: segment)
            return true
        case .message(.error(let code, let message)):
            segmentFailed(seq, reason: Self.friendly(code: code, message: message))
            return true
        case .message(.unknown):
            break
        case .closed(let reason):
            segmentFailed(seq, reason: reason ?? "connection closed")
            return true
        }
        return false
    }

    /// The final without the words that belong to a neighbour across an overlapped cut.
    private func joinTrimmed(_ f: FinalResult, seq: Int) -> NotesJoin.Final {
        let final = NotesJoin.Final(raw: f.raw, text: f.text, words: f.words)
        guard let s = segments[seq], s.leading > 0 || s.trailing > 0 else { return final }
        if f.words?.isEmpty == false {
            return NotesJoin.trim(final, leading: s.leading, trailing: s.trailing, duration: (s.end ?? router.seconds) - s.offset)
        }
        guard s.leading > 0, let previous = lastFinal, previous.seq == seq - 1 else { return final }
        return NotesJoin.dedupe(final, after: previous.text)
    }

    private func segmentFailed(_ seq: Int, reason: String) {
        guard let segment = segments[seq] else { return }
        if state == .starting, !sawReady, seq == current {
            // The very first socket never got going: nothing is recording yet.
            let message = reason == "Server unreachable" && !serverHost.isEmpty ? "Server unreachable at \(serverHost)" : reason
            drop(seq)
            _ = router.swap(to: nil)
            current = nil
            results.removeAll()
            nextCommit = nextSeq
            state = .error(message)
            changed()
            return
        }
        failureStreak += 1
        finish(seq, with: .gap(id: seq, offset: segment.offset, reason: reason))
        guard state == .recording else { return }
        if failureStreak >= Self.maxSegmentFailures {
            Task { await self.finish(error: "Notes stopped: \(reason)") }
        } else if seq == current {
            // The capturing socket died: roll to a fresh one so recording continues.
            Task { await self.cut() }
        }
    }

    private func drop(_ seq: Int) {
        guard let s = segments.removeValue(forKey: seq) else { return }
        s.timeout?.cancel()
        Task { await s.session.close() }
    }

    /// A segment is done: commit every finished segment that is next in order, then see whether a pass can run.
    private func finish(_ seq: Int, with segment: NotesSegment?) {
        drop(seq)
        results[seq] = .some(segment)
        while let next = results.removeValue(forKey: nextCommit) {
            if let s = next {
                document.append(s)
                if var job = labelJobs.removeValue(forKey: nextCommit) {
                    job.segment = document.segments.count - 1
                    labelQueue.append(job)
                }
            }
            labelJobs[nextCommit] = nil
            nextCommit += 1
            lastCommit = now()
        }
        drainLabels()
        updateLivePartial()
        schedule()
        changed()
    }

    /// The tail under the notes: the last partials of the segments still finalizing, then the current one's.
    private func updateLivePartial() {
        document.livePartial = segments.keys.sorted().compactMap { segments[$0]?.partial }.filter { !$0.isEmpty }.joined(separator: " ")
        changed()
    }

    // MARK: editing

    /// The editor changed the text (typing, paste, undo/redo, a task toggle): forwarded to the document. A claim of
    /// the tail drops a held append (its generation is gone) and may unblock the next pass.
    public func userEdit(_ range: NSRange, _ replacement: String, kind: NotesTextChange.Kind = .user) {
        let generation = document.windowGeneration
        document.userEdit(range, replacement, kind: kind)
        lastKeystroke = now()
        if document.windowGeneration != generation { dropHeld() }
        if case .applied = reorganizeState { reorganizeState = .idle }
        if held != nil { armHold() }
        schedule()
        changed()
    }

    /// Where the editor's caret is: in the tail (with focus) or composing marked text holds appends; leaving releases
    /// a held one.
    public func setEditorFocus(inTail: Bool, composing: Bool) {
        editorInTail = inTail
        editorComposing = composing
        if held != nil, !inTail, !composing { releaseHeld() }
    }

    /// The Reorganize button: runs at the first moment the pass slot is free, whatever the thresholds say.
    public func reorganizeNow() {
        guard state != .stopping, !structuring.isOff, reorganizeSupported else { return }
        manualReorganize = true
        schedule()
        changed()
    }

    /// The user's "Auto-reorganize" toggle.
    public func setAutoReorganize(_ on: Bool) {
        autoReorganize = on
        schedule()
        changed()
    }

    /// An append would land under the user's typing: IME is composing, or the caret is in the tail and a key was
    /// pressed within `holdMax`.
    private var holdsAppends: Bool { editorComposing || (editorInTail && typedRecently) }
    private var typedRecently: Bool { lastKeystroke.map { now() - $0 < Self.holdMax } ?? false }

    private func dropHeld() {
        held = nil
        holdTask?.cancel()
        holdTask = nil
    }

    private func releaseHeld() {
        guard let h = held else { return }
        dropHeld()
        applyAppend(h.request, h.response)
        schedule()
        changed()
    }

    /// Applies the held append once `holdMax` passed without a keystroke (never while IME is composing).
    private func armHold() {
        guard held != nil else { return }
        holdTask?.cancel()
        // Composing alone re-checks every `holdMax`; the end of composition releases it sooner (`setEditorFocus`).
        let wait = typedRecently ? Self.holdMax - (now() - (lastKeystroke ?? now())) : Self.holdMax
        let sleep = self.sleep, myEpoch = epoch
        holdTask = Task {
            await sleep(.milliseconds(Int((wait * 1000).rounded(.up))))
            guard !Task.isCancelled, self.epoch == myEpoch, self.held != nil else { return }
            self.holdTask = nil
            if !self.holdsAppends { self.releaseHeld() } else { self.armHold() }
        }
    }

    // MARK: passes

    /// The single pass slot, shared by append and reorganize. Nothing runs while a pass is in flight or a segment is
    /// still finalizing. Then: an append when one is due (fresh notes beat tidy notes), else a manual reorganize,
    /// else an automatic one once enough was added, enough time passed and the user stopped typing.
    private func schedule() {
        guard !structuring.isOff else { return }
        guard passTask == nil, finalizingCount == 0, labelQueue.isEmpty else { pending = true; return }
        relabelSettled()
        pending = false
        var appendWaiting = false
        if state.isCapturing {
            publish(document.freezeOverflow())
            // A held answer already covers its window: only newer segments are worth another pass.
            if let next = document.nextStructureRequest(), next.windowEnd > held?.request.windowEnd ?? -1 {
                if let last = lastPassEnd, now() - last < Self.minInterval {
                    appendWaiting = true
                    pending = true
                    armTimer(after: Self.minInterval - (now() - last))
                } else if let request = document.nextStructureRequest() {
                    run(request)
                    return
                }
            }
        }
        if manualReorganize, state != .stopping {
            manualReorganize = false
            runOrganize()
            return
        }
        // Auto, while recording: only in the quiet stretch right after a segment commit (its append, if due, runs
        // first), on at most the trailing `recordingReorganizeChars`. When anything else holds it back, the next
        // commit looks again; no timer.
        let t = now()
        guard !appendWaiting, autoReorganize, reorganizeSupported, state == .recording, held == nil,
              let commit = lastCommit, t - commit <= Self.reorganizeAfterCommit,
              document.charsSinceReorganize >= Self.reorganizeEveryChars,
              lastReorganizeEnd.map({ t - $0 >= (reorganizeRetry ? Self.reorganizeRetryAfter : Self.reorganizeMinInterval) }) ?? true,
              lastKeystroke.map({ t - $0 >= Self.typingIdle }) ?? true,
              let request = document.reorganizeRequest(final: false, manual: false, maxChars: NotesDocument.recordingReorganizeChars)
        else { return }
        runReorganize(request, manual: false)
    }

    /// The one timer: wakes `schedule()` at the earliest deadline anything is waiting for.
    private func armTimer(after seconds: TimeInterval) {
        let deadline = now() + seconds
        if timer != nil, let d = timerDeadline, d <= deadline { return }
        timer?.cancel()
        timerDeadline = deadline
        let sleep = self.sleep, myEpoch = epoch
        timer = Task {
            await sleep(.milliseconds(Int((seconds * 1000).rounded(.up))))
            guard !Task.isCancelled, self.epoch == myEpoch else { return }
            self.timer = nil
            self.timerDeadline = nil
            if self.pending {
                self.schedule()
                self.changed()
            }
        }
    }

    private func run(_ request: NotesStructureRequest) {
        structuring = .running
        passKind = .append
        changed()
        let myEpoch = epoch
        passTask = Task {
            let (response, disable) = await self.callStructure(request)
            guard self.epoch == myEpoch else { return }
            // A rejected window is retried in halves (then quarters) before any of it falls back to raw text.
            if disable == nil, response.error == "rejected", let (a, b) = NotesDocument.split(request.transcript) {
                var outcome = PieceOutcome()
                let first = await self.structurePieces(a, outline: request.outline, final: request.final, depth: 1, outcome: &outcome)
                let second = await self.structurePieces(b, outline: request.outline + Self.headings(first), final: request.final,
                                                        depth: 1, outcome: &outcome)
                guard self.epoch == myEpoch else { return }
                self.splitFinished(request, first + second, outcome)
                return
            }
            self.passFinished(request, response, disable: disable)
        }
    }

    /// One structuring call, with transport errors mapped to a failed answer (and what turns structuring off).
    private func callStructure(_ request: NotesStructureRequest) async -> (NotesStructureResponse, StructuringOff?) {
        do {
            return (try await structure(request), nil)
        } catch let error as NotesStructureError {
            switch error {
            case .off: return (.failed(error.code), .correctionOff)
            case .unsupported: return (.failed(error.code), .unsupported)
            default: return (.failed(error.code), nil)
            }
        } catch let error as URLError where error.code == .timedOut {
            return (.failed("timeout"), nil)
        } catch {
            return (.failed("http"), nil)
        }
    }

    private func callReorganize(_ request: NotesReorganizeRequest) async -> (NotesReorganizeResponse, NotesStructureError?) {
        do {
            return (try await reorganize(request), nil)
        } catch let error as NotesStructureError {
            return (.failed(error.code), error)
        } catch let error as URLError where error.code == .timedOut {
            return (.failed("timeout"), nil)
        } catch {
            return (.failed("http"), nil)
        }
    }

    /// What structuring parts of a text came to.
    private struct PieceOutcome {
        /// The deepest split that produced a result.
        var depth = 0
        /// Why each part that stayed raw failed (`rejected: novel_name`).
        var failures: [String] = []
        /// A part failed for a reason splitting cannot help (timeout, busy, http): the whole text keeps the normal retry.
        var transient: String?
        var disable: StructuringOff?

        var usable: Bool { transient == nil && disable == nil }
    }

    /// Structures `text` as one or more parts: a text over the window cap is cut first, and a part the server rejects
    /// is split at a sentence end (halves, then quarters, never under `minSplitChars`). A part that still fails at
    /// the smallest size comes back as a fallback piece, and only that part.
    private func structurePieces(_ text: String, outline: [String], final: Bool, depth: Int,
                                 outcome: inout PieceOutcome) async -> [NotesPiece] {
        guard outcome.usable else { return [.fallback(text)] }
        if text.count > NotesDocument.maxWindowChars, let (a, b) = NotesDocument.split(text) {
            let first = await structurePieces(a, outline: outline, final: final, depth: depth, outcome: &outcome)
            return first + (await structurePieces(b, outline: outline + Self.headings(first), final: final, depth: depth, outcome: &outcome))
        }
        let (response, disable) = await callStructure(NotesStructureRequest(transcript: text, outline: NotesDocument.capOutline(outline),
                                                                            final: final))
        if let disable { outcome.disable = disable; return [.fallback(text)] }
        if response.structured, let md = response.markdown?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty {
            outcome.depth = max(outcome.depth, depth)
            return [.markdown(md)]
        }
        guard response.error == "rejected" else {
            outcome.transient = response.failureLabel
            return [.fallback(text)]
        }
        if depth < Self.maxSplitDepth, let (a, b) = NotesDocument.split(text) {
            let first = await structurePieces(a, outline: outline, final: final, depth: depth + 1, outcome: &outcome)
            return first + (await structurePieces(b, outline: outline + Self.headings(first), final: final, depth: depth + 1,
                                                  outcome: &outcome))
        }
        outcome.depth = max(outcome.depth, depth)
        outcome.failures.append(response.failureLabel)
        return [.fallback(text)]
    }

    private static func headings(_ pieces: [NotesPiece]) -> [String] {
        pieces.flatMap { piece -> [String] in if case .markdown(let md) = piece { NotesMarkdown.headings(md) } else { [] } }
    }

    /// The parts of a split window: appended in order (a part that kept failing as a fallback block), and the tail
    /// settles. A transient failure of any part leaves the whole window to the normal retry.
    private func splitFinished(_ request: NotesStructureRequest, _ pieces: [NotesPiece], _ outcome: PieceOutcome) {
        if let transient = outcome.transient {
            passFinished(request, .failed(transient), disable: nil)
            return
        }
        passTask = nil
        passKind = nil
        lastPassEnd = now()
        if let disable = outcome.disable {
            structuringAllowed = .off(disable)
            structuring = .off(disable)
        } else {
            dropHeld()
            publish(document.applyPieces(pieces, for: request))
            if !structuring.isOff { structuring = outcome.failures.first.map { .failed($0) } ?? .idle }
            onPassEvent?(.split(windowChars: request.transcript.count, depth: outcome.depth, parts: pieces.count,
                                fallbacks: outcome.failures.count))
        }
        if pending || state.isCapturing { schedule() }
        changed()
    }

    private func passFinished(_ request: NotesStructureRequest, _ response: NotesStructureResponse, disable: StructuringOff?) {
        passTask = nil
        passKind = nil
        lastPassEnd = now()
        if let disable {
            structuringAllowed = .off(disable)
            structuring = .off(disable)
        } else if response.structured, holdsAppends, state != .stopping {
            // The caret is in the tail: keep the newest answer until it leaves (or the user goes quiet).
            held = (request, response)
            armHold()
            structuring = .idle
        } else {
            if response.structured { dropHeld() }
            applyAppend(request, response)
        }
        if pending || state.isCapturing { schedule() }
        changed()
    }

    private func applyAppend(_ request: NotesStructureRequest, _ response: NotesStructureResponse) {
        publish(document.apply(response, for: request))
        if !structuring.isOff { structuring = response.structured ? .idle : .failed(response.failureLabel) }
    }

    private func runReorganize(_ request: NotesReorganizeRequest, manual: Bool) {
        reorganizeState = .running
        passKind = .reorganize
        changed()
        let myEpoch = epoch
        passTask = Task {
            let (response, failure) = await self.callReorganize(request)
            guard self.epoch == myEpoch else { return }
            self.reorganizeFinished(request, response, manual: manual, failure: failure)
        }
    }

    /// Organize (the button): structure what auto-updates left raw — the pending window and every fallback block the
    /// user has not edited, each replaced in place — then reorganize the scope. Without anything raw it is a plain
    /// manual reorganize.
    private func runOrganize() {
        publish(document.freezeOverflow())
        let window = state.isCapturing || state == .idle || state == .stopped ? document.nextStructureRequest() : nil
        let blocks = document.untouchedFallbacks
        guard window != nil || !blocks.isEmpty || document.organizesInSteps else {
            if let request = document.reorganizeRequest(final: false, manual: true) {
                runReorganize(request, manual: true)
            } else {
                reorganizeState = document.reorganizeTooLong ? .tooLong : .idle
                changed()
            }
            return
        }
        var total = (window == nil ? 0 : 1) + blocks.count + (document.organizesInSteps ? document.organizeGroupCount() + 1 : 1)
        passKind = .reorganize
        reorganizeState = .organizing(step: 1, of: total)
        changed()
        let myEpoch = epoch
        passTask = Task {
            var failures: [String] = []
            var step = 1
            @MainActor func advance() {
                step += 1
                self.reorganizeState = .organizing(step: min(step, total), of: total)
                self.changed()
            }
            @MainActor func failed(_ outcome: PieceOutcome) {
                failures.append(outcome.transient ?? outcome.failures.first ?? "rejected")
            }
            if let window {
                var outcome = PieceOutcome()
                let pieces = await self.structurePieces(window.transcript, outline: window.outline, final: false, depth: 0,
                                                        outcome: &outcome)
                guard self.epoch == myEpoch else { return }
                if outcome.usable, pieces.contains(where: { if case .markdown = $0 { true } else { false } }) {
                    self.dropHeld()
                    self.publish(self.document.applyPieces(pieces, for: window))
                    failures += outcome.failures
                } else {
                    failed(outcome)                 // left in the window for the next append
                }
                advance()
            }
            let version = self.document.version
            var replacements: [(block: String, pieces: [NotesPiece])] = []
            for block in blocks {
                var outcome = PieceOutcome()
                let pieces = await self.structurePieces(block.body, outline: self.document.outline, final: false, depth: 0,
                                                        outcome: &outcome)
                guard self.epoch == myEpoch else { return }
                if outcome.usable, pieces.contains(where: { if case .markdown = $0 { true } else { false } }) {
                    replacements.append((block.block, pieces))
                    failures += outcome.failures
                } else {
                    failed(outcome)                 // kept as is
                }
                advance()
            }
            var conflict = false
            if !replacements.isEmpty {
                // Version-checked as one batch: an edit (or a composition) while it ran discards all of it.
                let changes = self.editorComposing ? [] : self.document.replaceFallbacks(replacements, ifVersion: version)
                if changes.isEmpty { conflict = true } else { changes.forEach { self.publish($0) } }
            }
            if !conflict, self.reorganizeSupported, self.document.organizesInSteps {
                total = step - 1 + self.document.organizeGroupCount() + 1
                self.reorganizeState = .organizing(step: min(step, total), of: total)
                guard let result = await self.reorganizeInSteps(final: false, advance: advance) else { return }
                failures += result.failures
                conflict = result.conflict
                if result.applied, failures.isEmpty, !conflict { self.reorganizeState = .applied(at: self.now()) }
            } else if !conflict, self.reorganizeSupported, let request = self.document.reorganizeRequest(final: false, manual: true) {
                let (response, failure) = await self.callReorganize(request)
                guard self.epoch == myEpoch else { return }
                _ = self.applyReorganizeResult(request, response, manual: true, failure: failure)
                switch self.reorganizeState {
                case .failed(let label): failures.append(label)
                case .conflict: conflict = true
                default: break
                }
            }
            self.passTask = nil
            self.passKind = nil
            if conflict {
                self.reorganizeState = .conflict
            } else if case .applied = self.reorganizeState, failures.isEmpty {
                // Organized, with the chip's Undo.
            } else {
                self.reorganizeState = .organized(failed: failures.count, reason: failures.first)
            }
            self.onPassEvent?(.organize(steps: total, failed: failures.count, conflict: conflict))
            self.schedule()
            self.changed()
        }
    }

    private func reorganizeFinished(_ request: NotesReorganizeRequest, _ response: NotesReorganizeResponse, manual: Bool,
                                    failure: NotesStructureError?) {
        passTask = nil
        passKind = nil
        if applyReorganizeResult(request, response, manual: manual, failure: failure) {
            // Not run: a segment clean-up took the model. No note and no backoff; the next commit tries again (a
            // manual one stays asked for).
            lastCommit = nil                       // this quiet stretch is used up
            schedule()
            if manual { manualReorganize = true }
            changed()
            return
        }
        schedule()
        changed()
    }

    /// Records a reorganize answer and applies it when the text is still what it was made from. True when the
    /// server preempted it (it did not run).
    private func applyReorganizeResult(_ request: NotesReorganizeRequest, _ response: NotesReorganizeResponse, manual: Bool,
                                       failure: NotesStructureError?) -> Bool {
        if response.preempted, failure == nil {
            reorganizeState = .idle
            return true
        }
        lastReorganizeEnd = now()
        versionAtReorganizeEnd = document.version
        reorganizeRetry = true
        switch failure {
        case .unsupported:
            // An older server: only Reorganize goes away; appends keep working.
            reorganizeEndpointMissing = true
            reorganizeSupported = false
            reorganizeState = .idle
        case .off:
            structuringAllowed = .off(.correctionOff)
            structuring = .off(.correctionOff)
            reorganizeState = .idle
        default:
            if request.version != document.version || request.documentID != document.id {
                reorganizeState = manual ? .conflict : .idle
            } else if editorComposing {
                // An input method is composing text the model has not seen: never replace under it.
                reorganizeState = manual ? .conflict : .idle
            } else if !response.reorganized {
                reorganizeState = .failed(response.failureLabel)
            } else {
                reorganizeRetry = false
                if let change = document.applyReorganize(response, for: request) {
                    // A held append was for the tail this just settled.
                    dropHeld()
                    publish(change)
                    reorganizeState = .applied(at: now())
                } else {
                    reorganizeState = .idle
                }
            }
        }
        return false
    }

    /// Whole-document reorganize (`NotesOrganize`): each group of sections oldest first, then the merge pass. Each
    /// step applies only to the text it was made from: an edit (or a composition) while one runs ends the run as a
    /// conflict and keeps the steps already applied. All its changes share one run number, so they undo as one step.
    /// Nil when the document was replaced meanwhile.
    private func reorganizeInSteps(final: Bool, advance: () -> Void) async -> (failures: [String], conflict: Bool, applied: Bool)? {
        let myEpoch = epoch
        organizeRuns += 1
        let run = organizeRuns
        var failures: [String] = [], applied = false, cursor = 0
        enum Step { case applied([NotesTextChange]), unchanged, failed(String), conflict, stop }
        func call(_ request: NotesReorganizeRequest, apply: (NotesReorganizeResponse) -> [NotesTextChange]) async -> Step? {
            var attempt = 0
            while true {
                let (response, failure) = await callReorganize(request)
                guard epoch == myEpoch else { return nil }
                if response.preempted, failure == nil {
                    guard attempt < Self.stepRetries else { return .failed("busy") }
                    attempt += 1
                    await sleep(Self.stepRetryAfter)
                    guard epoch == myEpoch else { return nil }
                    continue
                }
                lastReorganizeEnd = now()
                switch failure {
                case .unsupported:
                    reorganizeEndpointMissing = true
                    reorganizeSupported = false
                    return .stop
                case .off:
                    structuringAllowed = .off(.correctionOff)
                    structuring = .off(.correctionOff)
                    return .stop
                default: break
                }
                if request.version != document.version || request.documentID != document.id || editorComposing { return .conflict }
                guard response.reorganized else { return .failed(response.failureLabel) }
                let changes = apply(response)
                return changes.isEmpty ? .unchanged : .applied(changes)
            }
        }
        func record(_ step: Step) -> Bool {
            switch step {
            case .applied(let changes):
                dropHeld()
                changes.forEach { publish($0) }
                applied = true
            case .unchanged: break
            case .failed(let label): failures.append(label)
            case .conflict, .stop: return false
            }
            return true
        }
        var conflict = false
        while let request = document.organizeStep(from: cursor, final: final) {
            guard let step = await call(request, apply: { response in
                guard var change = self.document.applyReorganize(response, for: request) else { return [] }
                change.run = run
                return [change]
            }) else { return nil }
            if case .applied(let changes) = step {
                cursor = request.range.location + changes[0].replacement.utf16.count
            } else {
                cursor = NSMaxRange(request.range)
            }
            guard record(step) else {
                if case .conflict = step { conflict = true }
                break
            }
            advance()
        }
        if !conflict, reorganizeSupported, !structuring.isOff, let request = document.organizeMergeRequest(final: final) {
            guard let step = await call(request, apply: { self.document.applyMerge($0, for: request, run: run) }) else { return nil }
            if !record(step), case .conflict = step { conflict = true }
            advance()
        }
        versionAtReorganizeEnd = document.version
        reorganizeRetry = conflict || !failures.isEmpty
        return (failures, conflict, applied)
    }

    // MARK: speaker labels

    /// Labels committed segments in order: each waits until the diarizer settled its audio, or `labelTimeout` after
    /// its final, then gets its turns. A pass waiting on them runs once the queue is empty.
    private func drainLabels() {
        guard labelTask == nil, !labelQueue.isEmpty, let speakers = activeSpeakers else { return }
        let sleep = self.sleep
        labelTask = Task {
            while let job = self.labelQueue.first {
                let timeline = speakers.snapshot
                let settled = timeline.finalizedThrough + 0.001 >= job.end
                guard settled || self.now() - job.received >= Self.labelTimeout else {
                    await sleep(Self.labelPoll)
                    if Task.isCancelled { return }
                    continue
                }
                self.label(job, timeline: timeline, tentative: !settled)
                self.labelQueue.removeFirst()
                self.onLabels?(self.now() - job.received, !settled)
                self.changed()
            }
            self.labelTask = nil
            if self.pending { self.schedule() }
            self.changed()
        }
    }

    private func label(_ job: LabelJob, timeline: SpeakerTimeline, tentative: Bool) {
        if tentative { tentativeJobs.append(job) }
        guard let turns = SpeakerAttribution.turns(words: job.words, raw: job.raw, text: job.text, offset: job.offset,
                                                   end: job.end,
                                                   spans: timeline.labellingSpans(includeTentative: tentative, near: job.offset...max(job.end, job.offset)),
                                                   previousSlot: document.lastSpeakerSlot) else { return }
        document.attachSpeakers(turns, toSegment: job.segment, tentative: tentative)
    }

    /// Labels attached at the timeout are attached again from the settled timeline once it covers them (before a
    /// pass, so the notes see the better labels).
    private func relabelSettled() {
        guard !tentativeJobs.isEmpty, let speakers = activeSpeakers else { return }
        let timeline = speakers.snapshot
        let settled = tentativeJobs.filter { timeline.finalizedThrough + 0.001 >= $0.end }
        guard !settled.isEmpty else { return }
        tentativeJobs.removeAll { timeline.finalizedThrough + 0.001 >= $0.end }
        for job in settled { label(job, timeline: timeline, tentative: false) }
        changed()
    }

    private func dropLabels() {
        tentativeJobs.removeAll()
        labelTask?.cancel()
        labelTask = nil
        labelJobs.removeAll()
        labelQueue.removeAll()
    }

    // MARK: stopping

    private func finish(error: String?) async {
        guard state.isCapturing else { return }
        let myEpoch = epoch
        stoppingSince = now()
        defer { stoppingSince = nil }
        state = .stopping
        timer?.cancel()
        timer = nil
        pending = false
        manualReorganize = false
        let swap = router.swap(to: nil)
        if let seq = current {
            segments[seq]?.end = swap.offset
            let joins = segments[seq]?.joins == true
            segments[seq]?.pause = joins ? swap.pause : nil
        }
        if let seq = current, let old = swap.old, segments[seq] != nil { finalize(seq, old) }
        current = nil
        router.setSpeakers(nil)
        // The tail settles while the last final decodes; the session stays open for the next Record.
        let flush = activeSpeakers.map { speakers in Task { await speakers.flush() } }
        await waitUntil { self.segments.isEmpty && self.passTask == nil && self.labelQueue.isEmpty }
        // Record cannot start before this returns, so the Stop silence is in the model before any new audio.
        await flush?.value
        relabelSettled()
        guard epoch == myEpoch else { return }
        if let h = held {
            dropHeld()
            applyAppend(h.request, h.response)
        }
        publish(document.freezeOverflow())
        if !structuring.isOff, let request = document.nextStructureRequest(final: true) {
            run(request)
            await waitUntil { self.passTask == nil }
            guard epoch == myEpoch else { return }
        }
        publish(document.freezeAll(structuring: !structuring.isOff))
        document.livePartial = ""
        // One final reorganize, unless one just ran on this very text (it would only take time: up to 50 s more).
        let justTried = versionAtReorganizeEnd == document.version
            && (lastReorganizeEnd.map { now() - $0 < Self.stopReorganizeSkip } ?? false)
        if !structuring.isOff, autoReorganize, reorganizeSupported, !justTried, document.version != document.lastReorganizeVersion,
           document.organizesInSteps {
            // A long document is organized whole at Stop, in steps, so its start is merged with its end too.
            let total = document.organizeGroupCount() + 1
            var step = 1
            passKind = .reorganize
            reorganizeState = .organizing(step: 1, of: total)
            changed()
            let result = await reorganizeInSteps(final: true) {
                step += 1
                self.reorganizeState = .organizing(step: min(step, total), of: total)
                self.changed()
            }
            guard epoch == myEpoch, let result else { return }
            passKind = nil
            reorganizeState = result.conflict ? .idle : result.applied && result.failures.isEmpty ? .applied(at: now())
                : result.failures.isEmpty ? .idle : .failed(result.failures[0])
            onPassEvent?(.organize(steps: total, failed: result.failures.count, conflict: result.conflict))
        } else if !structuring.isOff, autoReorganize, reorganizeSupported, !justTried, document.version != document.lastReorganizeVersion,
           let request = document.reorganizeRequest(final: true, manual: false) {
            runReorganize(request, manual: false)
            await waitUntil { self.passTask == nil }
            guard epoch == myEpoch else { return }
        }
        state = error.map { .error($0) } ?? .stopped
        changed()
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        if condition() { return }
        await withCheckedContinuation { waiters.append((condition, $0)) }
    }

    private func changed() {
        if !waiters.isEmpty {
            var keep: [(check: () -> Bool, resume: CheckedContinuation<Void, Never>)] = []
            var ready: [CheckedContinuation<Void, Never>] = []
            for w in waiters { if w.check() { ready.append(w.resume) } else { keep.append(w) } }
            waiters = keep
            for r in ready { r.resume() }
        }
        onChange?()
    }

    static func friendly(code: String, message: String) -> String {
        switch code {
        case "auth": "Server rejected the token"
        case "busy": "Server is busy"
        case "too_long": "Segment too long"
        case "bad_audio": "Audio not understood"
        case "engine": "Speech engine hiccup"
        default: message
        }
    }
}
