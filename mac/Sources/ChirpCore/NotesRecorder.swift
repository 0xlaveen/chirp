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

/// Routes capture frames to the current segment's socket and runs the segmenter, on the audio thread. The swap at a
/// cut is atomic under the lock, so every frame lands on exactly one socket, in order.
final class NotesFrameRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var target: StreamSession?
    private var segmenter = NotesSegmenter()
    private var cutRequested = false
    /// Audio routed in this document, bytes of 16 kHz PCM16 (the segment offsets and the elapsed time).
    private var bytes = 0
    /// Speaker labels: the diarizer hears exactly the frames the sockets get, stamped on the same clock.
    private var speakers: SpeakerDiarizing?

    /// Sends the frame on; true when the segmenter wants a cut (asked once until the next swap).
    func route(_ frame: Data, level: Level) -> Bool {
        lock.withLock {
            guard let target else { return false }
            target.sendAudio(frame)
            speakers?.feed(frame, at: Double(bytes) / (PCMConverter.sampleRate * 2))
            bytes += frame.count
            let duration = Double(frame.count / 2) / PCMConverter.sampleRate
            guard !cutRequested, segmenter.feed(level, duration: duration) else { return false }
            cutRequested = true
            return true
        }
    }

    /// Points capture at `next` (nil stops routing). Returns the old target and the audio offset of the switch.
    func swap(to next: StreamSession?) -> (old: StreamSession?, offset: TimeInterval) {
        lock.withLock {
            let old = target
            target = next
            segmenter.reset()
            cutRequested = false
            return (old, Double(bytes) / (PCMConverter.sampleRate * 2))
        }
    }

    var seconds: TimeInterval { lock.withLock { Double(bytes) / (PCMConverter.sampleRate * 2) } }

    func setSpeakers(_ diarizer: SpeakerDiarizing?) { lock.withLock { speakers = diarizer } }

    func resetTime() { lock.withLock { bytes = 0 } }
}

/// A Live Notes session: one long recording cut into ordinary `/v1/stream` utterances over rolling sockets, plus the
/// structuring passes that turn the transcript into Markdown. Every system edge (sockets, the structuring call, time)
/// is injected, so the logic runs in tests without a microphone or a network. Nothing here is logged or persisted.
@MainActor
public final class NotesRecorder {
    public typealias Structure = @Sendable (NotesStructureRequest) async throws -> NotesStructureResponse

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

    public private(set) var state: NotesRecorderState = .idle { didSet { if state != oldValue { changed() } } }
    public private(set) var document = NotesDocument()
    public private(set) var structuring: StructuringStatus
    public private(set) var debugRetention = false
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

    private let makeSession: (StartOptions) -> StreamSession
    private let structure: Structure
    private let now: () -> TimeInterval
    private let sleep: @Sendable (Duration) async -> Void
    private let router = NotesFrameRouter()

    private struct Segment {
        let session: StreamSession
        let offset: TimeInterval
        /// Where its audio ended (set at the cut that finalizes it).
        var end: TimeInterval?
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

    private var passTask: Task<Void, Never>?
    private var pending = false
    private var lastPassEnd: TimeInterval?
    private var timer: Task<Void, Never>?
    /// What the user and the server allow, independent of the running state.
    private var structuringAllowed: StructuringStatus
    private var epoch = 0
    private var waiters: [(check: () -> Bool, resume: CheckedContinuation<Void, Never>)] = []

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
    /// The diarizer the current recording feeds.
    private var activeSpeakers: SpeakerDiarizing?

    public init(makeSession: @escaping (StartOptions) -> StreamSession, structure: @escaping Structure,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                options: StartOptions, structuring: Bool, health: Health? = nil, serverHost: String = "") {
        self.makeSession = makeSession
        self.structure = structure
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

    // MARK: configuration

    /// The user's "Structure notes" toggle or new server health. Turning it on schedules a pass for what is waiting.
    public func configureStructuring(enabled: Bool, health: Health?) {
        structuringAllowed = .availability(health: health, enabled: enabled)
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
        if structuring.isOff, !structuringAllowed.isOff { structuring = .idle }
        state = .starting
        document.stampStart(Date())
        activeSpeakers = speakers
        router.setSpeakers(speakers)
        let seq = nextSeq
        nextSeq += 1
        let session = makeSession(options)
        let (_, offset) = router.swap(to: session)
        current = seq
        track(seq, session: session, offset: offset)
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
        document = NotesDocument()
        router.resetTime()
        dropLabels()
        speakers?.reset()
        failureStreak = 0
        state = .idle
        if !structuringAllowed.isOff { structuring = .idle }
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
        let (old, offset) = router.swap(to: next)
        let previous = current
        current = seq
        track(seq, session: next, offset: offset)
        if let previous { segments[previous]?.end = offset }
        if let previous, let old { finalize(previous, old) }
    }

    private func track(_ seq: Int, session: StreamSession, offset: TimeInterval) {
        var segment = Segment(session: session, offset: offset)
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

    /// Ask the old segment for its final, with a deadline.
    private func finalize(_ seq: Int, _ session: StreamSession) {
        Task { await session.stop() }
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
            let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = f.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let offset = segments[seq]?.offset ?? 0
            let kept = options.correction && !f.corrected && f.correctionError != nil
            let segment = text.isEmpty ? nil : NotesSegment(id: seq, offset: offset, raw: raw.isEmpty ? text : raw, text: text,
                                                            corrected: f.corrected, keptOriginal: kept)
            if let segment, activeSpeakers != nil {
                labelJobs[seq] = LabelJob(offset: offset, end: segments[seq]?.end ?? router.seconds, words: f.words,
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

    // MARK: structuring

    /// After each final: run a pass unless one is running, a segment is still being corrected, or the last one
    /// ended less than `minInterval` ago. Otherwise remember it and look again when that changes.
    private func schedule() {
        guard !structuring.isOff, state == .recording || state == .starting else { return }
        guard passTask == nil, finalizingCount == 0, labelQueue.isEmpty else { pending = true; return }
        if let last = lastPassEnd, now() - last < Self.minInterval {
            pending = true
            armTimer(after: Self.minInterval - (now() - last))
            return
        }
        pending = false
        document.freezeOverflow()
        guard let request = document.nextStructureRequest() else { return }
        run(request)
    }

    private func armTimer(after seconds: TimeInterval) {
        guard timer == nil else { return }
        let sleep = self.sleep, myEpoch = epoch
        timer = Task {
            await sleep(.milliseconds(Int((seconds * 1000).rounded(.up))))
            guard !Task.isCancelled, self.epoch == myEpoch else { return }
            self.timer = nil
            if self.pending { self.schedule() }
        }
    }

    private func run(_ request: NotesStructureRequest) {
        structuring = .running
        changed()
        let structure = self.structure, myEpoch = epoch
        passTask = Task {
            let response: NotesStructureResponse
            var disable: StructuringOff?
            do {
                response = try await structure(request)
            } catch let error as NotesStructureError {
                switch error {
                case .off: disable = .correctionOff
                case .unsupported: disable = .unsupported
                default: break
                }
                response = .failed(error.code)
            } catch let error as URLError where error.code == .timedOut {
                response = .failed("timeout")
            } catch {
                response = .failed("http")
            }
            guard self.epoch == myEpoch else { return }
            self.passFinished(request, response, disable: disable)
        }
    }

    private func passFinished(_ request: NotesStructureRequest, _ response: NotesStructureResponse, disable: StructuringOff?) {
        passTask = nil
        lastPassEnd = now()
        if let disable {
            structuringAllowed = .off(disable)
            structuring = .off(disable)
        } else {
            document.apply(response, for: request)
            if !structuring.isOff { structuring = response.structured ? .idle : .failed(response.error ?? "http") }
        }
        if pending { schedule() }
        changed()
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
        guard let turns = SpeakerAttribution.turns(words: job.words, raw: job.raw, text: job.text, offset: job.offset,
                                                   end: job.end, spans: timeline.labellingSpans(includeTentative: tentative),
                                                   previousSlot: document.lastSpeakerSlot) else { return }
        document.attachSpeakers(turns, toSegment: job.segment, tentative: tentative)
    }

    private func dropLabels() {
        labelTask?.cancel()
        labelTask = nil
        labelJobs.removeAll()
        labelQueue.removeAll()
    }

    // MARK: stopping

    private func finish(error: String?) async {
        guard state.isCapturing else { return }
        let myEpoch = epoch
        state = .stopping
        timer?.cancel()
        timer = nil
        pending = false
        let (old, end) = router.swap(to: nil)
        if let seq = current { segments[seq]?.end = end }
        if let seq = current, let old, segments[seq] != nil { finalize(seq, old) }
        current = nil
        router.setSpeakers(nil)
        if let speakers = activeSpeakers {
            // The tail settles while the last final decodes; the session stays open for the next Record.
            Task { await speakers.flush() }
        }
        await waitUntil { self.segments.isEmpty && self.passTask == nil && self.labelQueue.isEmpty }
        guard epoch == myEpoch else { return }
        document.freezeOverflow()
        if !structuring.isOff, let request = document.nextStructureRequest(final: true) {
            run(request)
            await waitUntil { self.passTask == nil }
            guard epoch == myEpoch else { return }
        }
        document.freezeAll(structuring: !structuring.isOff)
        document.livePartial = ""
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
