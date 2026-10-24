import Foundation

/// The bytes held by every Live Notes segment's audio, counted from the audio thread.
final class NotesAudioPool: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    var bytes: Int { lock.withLock { total } }
    fileprivate func add(_ n: Int) { lock.withLock { total += n } }
}

/// One segment's 16 kHz PCM16, held for replay until its final commits (the opt-in library may then persist AAC).
/// A segment whose socket
/// failed, or that was recorded while the server was offline, is sent again from it.
final class NotesSegmentAudio: @unchecked Sendable {
    private let lock = NSLock()
    private let pool: NotesAudioPool
    private var frames: [Data] = []
    private var count = 0
    private var released = false

    init(pool: NotesAudioPool) { self.pool = pool }

    func append(_ frame: Data) {
        let added = lock.withLock { () -> Bool in
            guard !released else { return false }
            frames.append(frame)
            count += frame.count
            return true
        }
        if added { pool.add(frame.count) }
    }

    var contents: [Data] { lock.withLock { frames } }
    var bytes: Int { lock.withLock { count } }

    /// The final committed (or the audio became a gap): the memory goes, and later frames are ignored.
    func release() {
        let freed = lock.withLock { () -> Int in
            released = true
            frames.removeAll()
            defer { count = 0 }
            return count
        }
        pool.add(-freed)
    }
}

/// Whether the segments reach the server.
public enum NotesConnection: Equatable, Sendable {
    case online
    /// A socket failed for a reason a retry can fix: capture goes on into memory (`kept` seconds of audio), and
    /// the oldest waiting segment is retried with a backoff.
    case offline(kept: TimeInterval)
    /// Back online, `segments` recorded while offline are being sent again.
    case catchingUp(segments: Int)
}

/// What a segment's failure means.
enum NotesSegmentFault: Equatable {
    /// Transient (closed, timed out, busy, engine, unreachable): its audio is replayed.
    case retry
    /// Nothing a retry fixes for this audio (`bad_audio`, `too_long`): a gap, and recording goes on.
    case gap
    /// Nothing a retry fixes at all (`auth`): a gap, and Notes stops with the reason.
    case stop

    static func of(code: String) -> Self {
        switch code {
        case "auth": .stop
        case "bad_audio", "too_long": .gap
        default: .retry
        }
    }

    /// A socket that ended with `reason` (`StreamSession.describe` and the audio gate's trips).
    static func of(closed reason: String) -> Self {
        if reason.contains("check the token") { return .stop }
        if reason == "Utterance too long" { return .gap }
        return .retry
    }
}

extension NotesRecorder {
    /// The waits between replay attempts while the server is offline; the last one repeats.
    public static let retryDelays: [TimeInterval] = [1, 2, 5, 10, 15]
    /// At most this much audio is kept for replay (16 kHz PCM16: about 58 MB); past it the oldest becomes a gap.
    public nonisolated static let maxKeptAudio: TimeInterval = 30 * 60
    /// After Stop, segments still waiting for the server get this long before they become gaps.
    public static let stopReplayLimit: TimeInterval = 60
    public static let offlineTooLong = "server offline too long"
    public static let offlineAtStop = "server offline"

    /// Whether the segments reach the server now.
    public var connection: NotesConnection {
        let waiting = segments.values.filter(\.replay).count
        if offline { return .offline(kept: Double(audioPool.bytes) / (PCMConverter.sampleRate * 2)) }
        return waiting > 0 ? .catchingUp(segments: waiting) : .online
    }

    /// Audio held for segments whose final has not committed, bytes (at most `keptAudioCap`).
    public var keptAudioBytes: Int { audioPool.bytes }

    /// The server answered again (health): a replay waiting for its backoff goes now.
    public func serverAvailable() {
        guard replayTask != nil, !retryNow else { return }
        retryNow = true
        changed()
    }

    /// A segment's socket failed for a reason a retry fixes: its audio waits for a replay, and new segments are kept
    /// in memory until a socket gets `ready` again. The capturing segment is cut at once, so its replay (which tells
    /// whether the server is back) starts now; capture goes on into the next segment's memory.
    func queueReplay(_ seq: Int) {
        guard var s = segments[seq] else { return }
        offline = true
        s.timeout?.cancel()
        s.timeout = nil
        if let session = s.session {
            if seq == current { router.detach(session) }
            Task { await session.cancel() }
        }
        s.session = nil
        s.replay = true
        s.replaying = false
        s.partial = ""
        s.correcting = false
        segments[seq] = s
        updateLivePartial()
        pumpReplays()
        if seq == current, state == .recording { Task { await self.cut() } }
    }

    /// Something waits for a replay, or the kept audio grew: drop what is over the cap, then make sure the queue runs.
    func pumpReplays() {
        evictOverCap()
        if replayTask == nil, nextReplay() != nil {
            let myEpoch = epoch
            replayTask = Task { await self.runReplays(myEpoch) }
        }
        changed()
    }

    /// The oldest segment that was cut and waits for a replay.
    private func nextReplay() -> Int? {
        segments.filter { $0.value.replay && !$0.value.replaying && $0.value.end != nil }.keys.min()
    }

    /// Replays waiting segments in capture order; after a failure, waits `retryDelays` (or until `serverAvailable`).
    private func runReplays(_ myEpoch: Int) async {
        var attempt = 0
        while epoch == myEpoch, let seq = nextReplay() {
            if await replay(seq, myEpoch) {
                attempt = 0
                continue
            }
            guard epoch == myEpoch else { return }
            await backoff(Self.retryDelays[min(attempt, Self.retryDelays.count - 1)], myEpoch)
            attempt += 1
        }
        guard epoch == myEpoch else { return }
        replayTask = nil
        changed()
    }

    /// One replay: a fresh socket, the kept audio as fast as it takes it, `stop`, and the final into the segment's
    /// own slot. True once the segment is done with (committed, or a gap that a retry cannot fix).
    private func replay(_ seq: Int, _ myEpoch: Int) async -> Bool {
        guard let audio = segments[seq]?.audio else { return true }
        let session = makeSession(options)
        segments[seq]?.session = session
        segments[seq]?.replaying = true
        listen(seq, session)
        changed()
        await session.open()
        _ = await session.sendBuffered(audio.contents)
        if epoch == myEpoch, segments[seq]?.session === session { finalize(seq, session) }
        await waitUntil { self.epoch != myEpoch || self.segments[seq]?.session !== session }
        return segments[seq] == nil
    }

    private func backoff(_ seconds: TimeInterval, _ myEpoch: Int) async {
        retryNow = false
        backoffToken += 1
        let token = backoffToken, sleep = self.sleep
        Task {
            await sleep(.milliseconds(Int((seconds * 1000).rounded())))
            guard self.backoffToken == token else { return }
            self.retryNow = true
            self.changed()
        }
        await waitUntil { self.retryNow || self.epoch != myEpoch }
        backoffToken += 1
    }

    /// Keeps the audio under `keptAudioCap`, with room for the capturing segment to reach its longest: the oldest
    /// waiting segments become one gap.
    private func evictOverCap() {
        let headroom = Int((NotesSegmenter.maxSegment + NotesSegmenter.overlap) * PCMConverter.sampleRate) * 2
        while audioPool.bytes > keptAudioCap - headroom, let seq = nextReplay() {
            let offset = segments[seq]?.offset ?? 0
            finish(seq, with: lastEvicted == seq - 1 ? nil : .gap(id: seq, offset: offset, reason: Self.offlineTooLong))
            lastEvicted = seq
        }
    }

    /// Stop waits `stopReplayLimit` for the server; then what still waits becomes a gap and Finishing completes.
    func limitStopReplays() {
        stops += 1
        let myEpoch = epoch, stop = stops, sleep = self.sleep
        Task {
            await sleep(.seconds(Self.stopReplayLimit))
            guard self.epoch == myEpoch, self.stops == stop, self.state == .stopping else { return }
            var previous = -2
            for seq in self.segments.keys.sorted() where self.segments[seq]?.replay == true {
                if let session = self.segments[seq]?.session { Task { await session.cancel() } }
                // One gap for a run of segments in a row.
                let gap = NotesSegment.gap(id: seq, offset: self.segments[seq]?.offset ?? 0, reason: Self.offlineAtStop)
                self.finish(seq, with: previous == seq - 1 ? nil : gap)
                previous = seq
            }
        }
    }
}
