import Foundation

/// One kept clip a re-transcribe sends: its segment, where its audio sits in the session, and what joins it to the
/// segment before.
public struct NotesRetranscribeClip: Equatable, Sendable {
    public var segment: Int
    /// Session seconds of the clip's first sample, and its length.
    public var offset: TimeInterval
    public var duration: TimeInterval
    /// Seconds at its start the previous clip also holds, and at its end the next one (the Mac's hard-cut overlap).
    public var leading: TimeInterval
    public var trailing: TimeInterval
    /// The segment before it, when this one follows it without a break: its text is clean-up context and the join's
    /// dedupe reference (the new text once that segment is re-transcribed too).
    public var previousText: String?

    public init(segment: Int, offset: TimeInterval, duration: TimeInterval, leading: TimeInterval = 0,
                trailing: TimeInterval = 0, previousText: String? = nil) {
        self.segment = segment
        self.offset = offset
        self.duration = duration
        self.leading = leading
        self.trailing = trailing
        self.previousText = previousText
    }
}

/// What the run has done so far ("Re-transcribing · 12 of 40 · 1:32 of 8:10").
public struct NotesRetranscribeProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public var audioDone: TimeInterval
    public var audioTotal: TimeInterval
    /// The server answered `busy` (or could not be reached) and the clip waits for a retry: "Waiting for your server…".
    public var waiting = false

    public init(done: Int, total: Int, audioDone: TimeInterval, audioTotal: TimeInterval, waiting: Bool = false) {
        self.done = done
        self.total = total
        self.audioDone = audioDone
        self.audioTotal = audioTotal
        self.waiting = waiting
    }

    public var fraction: Double { audioTotal > 0 ? min(1, audioDone / audioTotal) : (total > 0 ? Double(done) / Double(total) : 0) }
}

/// How a run ended, and what it staged. Nothing is applied by the runner: the caller applies `segments` in one write.
public struct NotesRetranscribeResult: Equatable, Sendable {
    public enum End: Equatable, Sendable {
        /// Every clip was tried; `failed` of them kept their old text.
        case finished
        /// Cancel: everything staged is dropped.
        case cancelled
        /// The server refused the pairing: nothing applies, and the client routes to re-pairing.
        case auth
        /// The server stayed busy or unreachable through every retry: nothing applies unless the user picks
        /// "Apply what’s done".
        case stopped(code: String)
    }

    public var end: End
    public var segments: [NotesRetranscribedSegment]
    /// Clips whose request failed (or decoded to nothing), keeping their old text.
    public var failed: Int
    public var total: Int
    /// Seconds of audio sent, for the counts-only log line.
    public var audio: TimeInterval
    /// The last error code (`engine`, `bad_audio`, `busy`…), for the log line.
    public var code: String?

    /// `notes retranscribe segments=40 audio_ms=490000 updated=38 failed=2 code=engine`: counts only, no text, host or title.
    public var logLine: String {
        "notes retranscribe segments=\(total) audio_ms=\(Int((audio * 1000).rounded())) updated=\(segments.count) failed=\(failed) code=\(code ?? "none")"
    }
}

/// Sends a note's kept clips to the paired Chirp server again, one `WS /v1/stream` utterance per clip, in order
/// (#287 §3): `start.retranscribe` (no previews, behind live audio), word timings, the `live_notes` clean-up and the
/// previous segment's new text as `stop.context`. Results are staged in memory; nothing is logged or written. A
/// `busy` (or unreachable) server is retried with backoff; a failed clip keeps its old text. Cancel the calling task to
/// stop: the in-flight utterance gets `cancel` and the result says `.cancelled`. Platform-neutral (Mac and iOS).
public final class NotesRetranscriber: @unchecked Sendable {
    /// The waits before retrying a clip the server was too busy for (the last repeats), and how many retries.
    public static let busyDelays: [TimeInterval] = [2, 4, 8, 16, 30]
    public static let maxRetries = 10
    /// How long a final may take after `stop` (extended on `correcting` to the server's notes clean-up budget).
    public static let finalTimeout: TimeInterval = 25
    /// A re-transcribe `start` may wait this long for the engine before `ready` (the server's 60 s queue, plus slack).
    public static let readyDeadline: Duration = .seconds(75)
    /// PCM16 per frame sent (100 ms at 16 kHz).
    static let frameBytes = 3200

    private let makeSession: (StartOptions) -> StreamSession
    private let options: StartOptions
    private let contextSupported: Bool
    private let correctionTimeout: TimeInterval?
    private let audio: @Sendable (NotesRetranscribeClip) async throws -> Data
    private let wait: @Sendable (Duration) async -> Void
    private let deadline: @Sendable (Duration) async -> Void

    /// Called on every step, from the run's task.
    public var onProgress: (@Sendable (NotesRetranscribeProgress) -> Void)?

    /// `options` are the note's own start options (its clean-up setting); `retranscribe` and word timings are added.
    /// `audio` decodes one clip to 16 kHz mono PCM16 (`NotesAudioDecoder`). `wait` paces busy retries and `deadline`
    /// the final's timeout (tests pass their own).
    public init(makeSession: @escaping (StartOptions) -> StreamSession, options: StartOptions, health: Health?,
                audio: @escaping @Sendable (NotesRetranscribeClip) async throws -> Data,
                wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                deadline: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.makeSession = makeSession
        var o = options
        o.retranscribe = true
        o.wordTimings = true
        o.speakersSession = nil
        self.options = o
        contextSupported = health?.notesContext == true
        let operation: ServerOperation = o.correctionProfile == CorrectionProfile.liveNotesID ? .notesCorrection : .dictation
        correctionTimeout = health?.operationDeadlines?.advertisedTimeout(for: operation)
        self.audio = audio
        self.wait = wait
        self.deadline = deadline
    }

    /// The clips of `document` that have kept audio (all of them, or only segment `only`), with the hard-cut overlap
    /// between neighbouring clips worked out from their offsets.
    public static func clips(for document: NotesDocument, only: Int? = nil) -> [NotesRetranscribeClip] {
        let refs = document.audio.filter { document.segments.indices.contains($0.id) }.sorted { $0.id < $1.id }
        let byID = Dictionary(refs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        func joined(_ id: Int) -> Bool { id > 0 && document.segments.indices.contains(id) && document.segments[id].pauseBefore != nil }
        func overlap(_ a: NotesAudioReference?, _ b: NotesAudioReference?) -> TimeInterval {
            guard let a, let b, b.id == a.id + 1, joined(b.id) else { return 0 }
            let shared = a.offset + a.duration - b.offset
            // Only a hard cut overlaps (at most `NotesSegmenter.overlap`); rounding between contiguous clips is not one.
            return shared > 0.02 ? min(shared, NotesSegmenter.overlap + 0.1) : 0
        }
        return refs.filter { only == nil || $0.id == only }.map { ref in
            NotesRetranscribeClip(segment: ref.id, offset: ref.offset, duration: ref.duration,
                                  leading: overlap(byID[ref.id - 1], ref), trailing: overlap(ref, byID[ref.id + 1]),
                                  previousText: joined(ref.id) ? document.segments[ref.id - 1].text : nil)
        }
    }

    /// Runs `clips` in order. Returns when every clip was tried, the server refused the pairing, it stayed busy past
    /// the retries, or the calling task was cancelled.
    public func run(_ clips: [NotesRetranscribeClip]) async -> NotesRetranscribeResult {
        let audioTotal = clips.reduce(0) { $0 + $1.duration }
        var result = NotesRetranscribeResult(end: .finished, segments: [], failed: 0, total: clips.count, audio: 0)
        var progress = NotesRetranscribeProgress(done: 0, total: clips.count, audioDone: 0, audioTotal: audioTotal)
        var newText: [Int: String] = [:]
        onProgress?(progress)
        for clip in clips {
            if Task.isCancelled { return cancelled(result) }
            let pcm: Data
            do { pcm = try await audio(clip) } catch {
                result.failed += 1
                result.code = "decode"
                progress.done += 1
                progress.audioDone += clip.duration
                onProgress?(progress)
                continue
            }
            if Task.isCancelled { return cancelled(result) }
            let previous = newText[clip.segment - 1] ?? clip.previousText
            let context = contextSupported && options.correction && options.correctionProfile == CorrectionProfile.liveNotesID
                ? previous.flatMap(NotesJoin.context) : nil
            let frames = stride(from: 0, to: pcm.count, by: Self.frameBytes).map { pcm[$0..<min($0 + Self.frameBytes, pcm.count)] }
            var retries = 0
            var outcome: Attempt
            while true {
                outcome = await attempt(frames.map { Data($0) }, context: context)
                guard outcome.isTransient, !Task.isCancelled else { break }
                guard retries < Self.maxRetries else { break }
                progress.waiting = true
                onProgress?(progress)
                await wait(.milliseconds(Int(Self.busyDelays[min(retries, Self.busyDelays.count - 1)] * 1000)))
                retries += 1
                if Task.isCancelled { return cancelled(result) }
            }
            progress.waiting = false
            switch outcome {
            case .cancelled:
                return cancelled(result)
            case .auth:
                result.end = .auth
                result.code = "auth"
                return result
            case .busy, .unreachable:
                result.end = .stopped(code: outcome.code)
                result.code = outcome.code
                return result
            case .failed(let code):
                result.failed += 1
                result.code = code
            case .final(let f, let engine):
                result.audio += Double(pcm.count) / (PCMConverter.sampleRate * 2)
                let joined = Self.trimmed(f, clip: clip, duration: Double(pcm.count) / (PCMConverter.sampleRate * 2),
                                          previous: previous)
                let text = joined.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    result.failed += 1
                    result.code = "empty"
                } else {
                    let kept = options.correction && !f.corrected && f.correctionError != nil
                    result.segments.append(NotesRetranscribedSegment(
                        segment: clip.segment, raw: joined.raw, text: text, corrected: f.corrected, keptOriginal: kept,
                        words: joined.words, clipOffset: clip.offset, engine: engine))
                    newText[clip.segment] = text
                }
            }
            progress.done += 1
            progress.audioDone += clip.duration
            onProgress?(progress)
        }
        return result
    }

    private func cancelled(_ result: NotesRetranscribeResult) -> NotesRetranscribeResult {
        var r = result
        r.end = .cancelled
        r.segments = []
        return r
    }

    /// The final without the words its neighbours hold across a hard cut (the live rule, `NotesJoin`): trimmed by word
    /// timings, then a first word or pair that repeats the previous segment's end is dropped.
    static func trimmed(_ f: FinalResult, clip: NotesRetranscribeClip, duration: TimeInterval, previous: String?) -> NotesJoin.Final {
        var final = NotesJoin.Final(raw: f.raw, text: f.text, words: f.words)
        guard clip.leading > 0 || clip.trailing > 0 else { return final }
        if f.words?.isEmpty == false {
            final = NotesJoin.trim(final, leading: clip.leading, trailing: clip.trailing, duration: duration)
        }
        guard clip.leading > 0, let previous else { return final }
        return NotesJoin.dedupe(final, after: previous)
    }

    // MARK: one utterance

    enum Attempt: Equatable {
        case final(FinalResult, engine: String?)
        /// Kept its old text (`engine`, `bad_audio`, `too_long`, `timeout`…).
        case failed(String)
        case busy, unreachable, auth, cancelled

        var isTransient: Bool { self == .busy || self == .unreachable }
        var code: String {
            switch self {
            case .busy: "busy"
            case .unreachable: "unreachable"
            case .auth: "auth"
            case .cancelled: "cancelled"
            case .failed(let code): code
            case .final: "none"
            }
        }
    }

    /// One clip over a fresh socket: `start`, the audio as fast as the socket takes it, `stop` with the context, then
    /// the final within its deadline.
    func attempt(_ frames: [Data], context: String?) async -> Attempt {
        let session = makeSession(options)
        let watch = Watchdog(deadline: deadline)
        await session.open()
        let finalTimeout = Self.finalTimeout
        let sender = Task {
            _ = await session.sendBuffered(frames)
            await session.stop(context: context)
            watch.arm(after: finalTimeout, replacing: false) { await session.cancel() }
        }
        defer {
            sender.cancel()
            watch.disarm()
        }
        return await withTaskCancellationHandler {
            var engine: String?
            for await event in session.events {
                switch event {
                case .message(.ready(_, let e, _)):
                    engine = e
                case .message(.correcting):
                    if let timeout = correctionTimeout { watch.arm(after: timeout, replacing: true) { await session.cancel() } }
                case .message(.final(let f)):
                    await session.close()
                    return .final(f, engine: engine)
                case .message(.error(let code, _)):
                    await session.close()
                    switch code {
                    case "auth": return .auth
                    case "busy": return .busy
                    default: return .failed(code)
                    }
                case .closed(let reason):
                    if Task.isCancelled { return .cancelled }
                    if watch.fired { return .failed("timeout") }
                    if let reason, NotesSegmentFault.of(closed: reason) == .stop { return .auth }
                    if reason == "Utterance too long" { return .failed("too_long") }
                    return .unreachable
                case .message(.partial), .message(.unknown):
                    break
                }
            }
            return Task.isCancelled ? .cancelled : .unreachable
        } onCancel: {
            Task { await session.cancel() }
        }
    }
}

/// The final's deadline for one utterance: armed after `stop`, re-armed (extended) on `correcting`.
private final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: @Sendable (Duration) async -> Void
    private var task: Task<Void, Never>?
    private var didFire = false
    private var extended = false

    init(deadline: @escaping @Sendable (Duration) async -> Void) { self.deadline = deadline }

    var fired: Bool { lock.withLock { didFire } }

    /// `replacing` false (after `stop`) never shortens a deadline `correcting` already extended.
    func arm(after seconds: TimeInterval, replacing: Bool, _ action: @escaping @Sendable () async -> Void) {
        let deadline = self.deadline
        lock.withLock {
            if !replacing, extended { return }
            if replacing { extended = true }
            task?.cancel()
            task = Task { [weak self] in
                await deadline(.milliseconds(Int(seconds * 1000)))
                guard !Task.isCancelled, let self else { return }
                self.lock.withLock { self.didFire = true }
                await action()
            }
        }
    }

    func disarm() { lock.withLock { task?.cancel() } }
}
