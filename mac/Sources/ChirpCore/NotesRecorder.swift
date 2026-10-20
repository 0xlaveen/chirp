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
    /// The notes changed while a manual reorganize ran, so its result was discarded.
    case conflict
    /// The last section alone is over `NotesDocument.maxReorganizeChars`.
    case tooLong
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

    /// Sends the frame on; true when the segmenter wants a cut (asked once until the next swap).
    func route(_ frame: Data, level: Level) -> Bool {
        lock.withLock {
            guard let target else { return false }
            target.sendAudio(frame)
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

    func resetTime() { lock.withLock { bytes = 0 } }
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
    /// Auto-reorganize waits for this many inserted characters (user or AI) since the last one…
    public static let reorganizeEveryChars = 1200
    /// …this long since the last one ended…
    public static let reorganizeMinInterval: TimeInterval = 180
    /// …and this long without a keystroke.
    public static let typingIdle: TimeInterval = 15
    /// After a failed or discarded reorganize, auto waits this long instead of `reorganizeMinInterval`.
    public static let reorganizeRetryAfter: TimeInterval = 60
    /// A held append is applied after this long without a keystroke, even with the caret in the tail.
    public static let holdMax: TimeInterval = 10

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

    private let makeSession: (StartOptions) -> StreamSession
    private let structure: Structure
    private let reorganize: Reorganize
    private let now: () -> TimeInterval
    private let sleep: @Sendable (Duration) async -> Void
    private let router = NotesFrameRouter()

    private struct Segment {
        let session: StreamSession
        let offset: TimeInterval
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
    private var waiters: [(check: () -> Bool, resume: CheckedContinuation<Void, Never>)] = []

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

    /// An append result is waiting for the caret to leave the tail.
    public var isHolding: Bool { held != nil }

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
        manualReorganize = false
        dropHeld()
        if reorganizeState == .running { reorganizeState = .idle }
        passKind = nil
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
        failureStreak = 0
        pendingChanges.removeAll()
        dropHeld()
        reorganizeState = .idle
        reorganizeRetry = false
        lastReorganizeEnd = nil
        lastKeystroke = nil
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
            if let s = next { document.append(s) }
            nextCommit += 1
        }
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
        guard passTask == nil, finalizingCount == 0 else { pending = true; return }
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
            if let request = document.reorganizeRequest(final: false, manual: true) {
                runReorganize(request, manual: true)
            } else {
                reorganizeState = document.reorganizeTooLong ? .tooLong : .idle
                changed()
            }
            return
        }
        guard !appendWaiting, autoReorganize, reorganizeSupported, state == .recording, held == nil,
              document.charsSinceReorganize >= Self.reorganizeEveryChars,
              let request = document.reorganizeRequest(final: false, manual: false) else { return }
        let t = now()
        var wait: TimeInterval = 0
        if let end = lastReorganizeEnd {
            wait = max(wait, (reorganizeRetry ? Self.reorganizeRetryAfter : Self.reorganizeMinInterval) - (t - end))
        }
        if let k = lastKeystroke { wait = max(wait, Self.typingIdle - (t - k)) }
        if wait > 0 {
            pending = true
            armTimer(after: wait)
            return
        }
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
            if self.pending { self.schedule() }
        }
    }

    private func run(_ request: NotesStructureRequest) {
        structuring = .running
        passKind = .append
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
        if !structuring.isOff { structuring = response.structured ? .idle : .failed(response.error ?? "http") }
    }

    private func runReorganize(_ request: NotesReorganizeRequest, manual: Bool) {
        reorganizeState = .running
        passKind = .reorganize
        changed()
        let reorganize = self.reorganize, myEpoch = epoch
        passTask = Task {
            let response: NotesReorganizeResponse
            var failure: NotesStructureError?
            do {
                response = try await reorganize(request)
            } catch let error as NotesStructureError {
                failure = error
                response = .failed(error.code)
            } catch let error as URLError where error.code == .timedOut {
                response = .failed("timeout")
            } catch {
                response = .failed("http")
            }
            guard self.epoch == myEpoch else { return }
            self.reorganizeFinished(request, response, manual: manual, failure: failure)
        }
    }

    private func reorganizeFinished(_ request: NotesReorganizeRequest, _ response: NotesReorganizeResponse, manual: Bool,
                                    failure: NotesStructureError?) {
        passTask = nil
        passKind = nil
        lastReorganizeEnd = now()
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
            if request.version != document.version {
                reorganizeState = manual ? .conflict : .idle
            } else if !response.reorganized {
                reorganizeState = .failed(response.error ?? "http")
            } else {
                reorganizeRetry = false
                if let change = document.applyReorganize(response, for: request) {
                    publish(change)
                    reorganizeState = .applied(at: now())
                } else {
                    reorganizeState = .idle
                }
            }
        }
        schedule()
        changed()
    }

    // MARK: stopping

    private func finish(error: String?) async {
        guard state.isCapturing else { return }
        let myEpoch = epoch
        state = .stopping
        timer?.cancel()
        timer = nil
        pending = false
        manualReorganize = false
        let (old, _) = router.swap(to: nil)
        if let seq = current, let old, segments[seq] != nil { finalize(seq, old) }
        current = nil
        await waitUntil { self.segments.isEmpty && self.passTask == nil }
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
        if !structuring.isOff, autoReorganize, reorganizeSupported, document.version != document.lastReorganizeVersion,
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
