import AVFoundation
import Foundation

/// Live Notes call audio (#211): what the Mac plays (the other people on a call) recorded beside the microphone, so
/// both sides are transcribed and labelled. The recognizer hears one 16 kHz mono mix; the speaker labels keep the two
/// apart: the microphone is "You", and only the call audio is diarized, so local and remote voices never merge.
/// Nothing here is logged except counts and the capture kind, and no audio is stored beyond the kept-audio rules.

/// An app whose output can be recorded on its own ("Zoom", "FaceTime", a browser for Meet).
public struct CallAudioApp: Equatable, Hashable, Sendable, Codable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    /// Call apps listed first in the picker (when they are running), in this order.
    public static let knownCallApps = [
        "us.zoom.xos", "com.apple.FaceTime", "com.microsoft.teams2", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "com.cisco.webexmeetingsapp", "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
    ]

    /// Known call apps first, then the rest by name; one entry per bundle.
    public static func sorted(_ apps: [CallAudioApp]) -> [CallAudioApp] {
        var seen = Set<String>()
        let unique = apps.filter { seen.insert($0.bundleID).inserted }
        func rank(_ app: CallAudioApp) -> Int { knownCallApps.firstIndex(of: app.bundleID) ?? knownCallApps.count }
        return unique.sorted { (rank($0), $0.name.localizedLowercase) < (rank($1), $1.name.localizedLowercase) }
    }
}

/// Where a Live Notes recording listens: the microphone, and optionally the call audio (every app, or one).
public struct NotesSources: Equatable, Sendable {
    public var callAudio: Bool
    /// The one app to record; nil records everything the Mac plays (except Chirp's own sounds).
    public var app: CallAudioApp?

    public init(callAudio: Bool = false, app: CallAudioApp? = nil) {
        self.callAudio = callAudio
        self.app = app
    }

    public static let microphone = NotesSources()

    /// "Microphone", "Microphone + call audio", "Microphone + Zoom".
    public var title: String {
        guard callAudio else { return "Microphone" }
        return "Microphone + " + (app?.name ?? "call audio")
    }
}

/// How call audio is captured, for the log and the status line.
public enum CallAudioKind: String, Sendable {
    /// Core Audio process taps (macOS 14.2+).
    case processTap = "process-tap"
    /// ScreenCaptureKit audio-only capture, when a tap cannot be made.
    case screenCapture = "screen-capture"
    /// A file played as if the Mac were playing it (the selftest).
    case file
}

public enum CallAudioError: Error, Equatable {
    /// The system refused (no permission, or the API is missing).
    case unavailable(String)
    /// Nothing to record: the app is not running or plays no audio.
    case noSource
}

/// The system-audio capture behind `CallAudioCapture`, so the pipeline runs in tests and the selftest without the OS
/// permission. Buffers arrive on any thread, in any format; `stop` is idempotent.
public protocol SystemAudioTap: AnyObject, Sendable {
    var kind: CallAudioKind { get }
    func start(app: CallAudioApp?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// Tries each tap in turn until one starts (process taps, then ScreenCaptureKit); remembers the one running.
public final class FallbackAudioTap: SystemAudioTap, @unchecked Sendable {
    private let taps: [SystemAudioTap]
    private let lock = NSLock()
    private var running: SystemAudioTap?

    public init(_ taps: [SystemAudioTap]) { self.taps = taps }

    public var kind: CallAudioKind { lock.withLock { running?.kind ?? taps.first?.kind ?? .processTap } }

    public func start(app: CallAudioApp?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stop()
        var last: Error = CallAudioError.unavailable("no tap")
        for tap in taps {
            do {
                try tap.start(app: app, onBuffer: onBuffer)
                lock.withLock { running = tap }
                return
            } catch {
                chirpLog.info("notes call audio \(tap.kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                last = error
            }
        }
        throw last
    }

    public func stop() {
        let tap = lock.withLock { () -> SystemAudioTap? in defer { running = nil }; return running }
        tap?.stop()
    }
}

/// One 50 ms step of a call recording: the mix the recognizer hears, and each side on its own (the speaker labels).
public struct CallFrame: Sendable {
    public var mix: Data
    public var mic: Data
    public var remote: Data
    public var micLevel: Level
    public var remoteLevel: Level
    /// The microphone only heard the call playing through the speakers (no headphones): it is left out of the mix
    /// and never labelled "You".
    public var micIsEcho: Bool

    public init(mix: Data, mic: Data, remote: Data, micLevel: Level, remoteLevel: Level, micIsEcho: Bool) {
        self.mix = mix
        self.mic = mic
        self.remote = remote
        self.micLevel = micLevel
        self.remoteLevel = remoteLevel
        self.micIsEcho = micIsEcho
    }
}

/// Mixes the call audio into the microphone's frames. The microphone is the clock: each mic frame takes the same
/// number of call samples from a small jitter buffer (taps deliver in bursts), so the mix and both sides stay on the
/// document clock. Echo gate: while the call is talking, a microphone much quieter than it is only hearing the
/// speakers, so it is left out of the mix (one copy of each remote word) and out of "You".
public final class CallAudioMixer: @unchecked Sendable {
    /// Call audio waits this long before it is played into the mix (bursty taps never underrun mid-word).
    public static let prime: TimeInterval = 0.15
    /// More than this queued (the call's clock runs ahead of the mic's) drops back to `prime`.
    public static let maxBacklog: TimeInterval = 1.0
    /// The call is talking at or above this RMS…
    public static let remoteActiveRMS: Float = 0.004
    /// …and a microphone under this share of the call's level only hears it through the speakers.
    public static let echoRatio: Float = 0.35
    /// The echo gate stays shut this long after the call goes quiet (the room's tail and the playback delay).
    public static let echoHangover: TimeInterval = 0.35

    private let lock = NSLock()
    private var queue = Data()
    private var primed = false
    private var remotePeakRMS: Float = 0
    private var sinceRemote: TimeInterval = .infinity
    public private(set) var underruns = 0
    public private(set) var dropped = 0

    public init() {}

    private static func bytes(_ seconds: TimeInterval) -> Int { Int(seconds * PCMConverter.sampleRate) * 2 }

    /// Call audio, 16 kHz mono PCM16, any length; from the tap's thread.
    public func pushRemote(_ pcm16: Data) {
        lock.withLock {
            queue.append(pcm16)
            if queue.count > Self.bytes(Self.maxBacklog) {
                let drop = queue.count - Self.bytes(Self.prime)
                queue.removeFirst(drop - drop % 2)
                dropped += 1
            }
        }
    }

    /// The call audio queued, in seconds (tests).
    public var backlog: TimeInterval { lock.withLock { Double(queue.count / 2) / PCMConverter.sampleRate } }

    /// One microphone frame in, one `CallFrame` out.
    public func mix(mic: Data) -> CallFrame {
        let need = mic.count - mic.count % 2
        let remote: Data = lock.withLock {
            if !primed, queue.count >= Self.bytes(Self.prime) { primed = true }
            guard primed else { return Data(count: need) }
            if queue.count >= need {
                let out = queue.prefix(need)
                queue.removeFirst(need)
                return Data(out)
            }
            var out = queue
            out.append(Data(count: need - queue.count))
            queue.removeAll()
            primed = false
            underruns += 1
            return out
        }
        let micLevel = Level(pcm16: mic), remoteLevel = Level(pcm16: remote)
        let duration = Double(need / 2) / PCMConverter.sampleRate
        let echo = lock.withLock { () -> Bool in
            if remoteLevel.rms >= Self.remoteActiveRMS {
                sinceRemote = 0
                remotePeakRMS = max(remotePeakRMS * 0.9, remoteLevel.rms)
            } else {
                sinceRemote += duration
                if sinceRemote > Self.echoHangover { remotePeakRMS = 0 }
            }
            return remotePeakRMS > 0 && micLevel.rms < remotePeakRMS * Self.echoRatio
        }
        return CallFrame(mix: Self.sum(echo ? nil : mic, remote), mic: mic, remote: remote, micLevel: micLevel,
                         remoteLevel: remoteLevel, micIsEcho: echo)
    }

    /// Drops what is queued (a pause or stop: the next capture starts clean).
    public func reset() {
        lock.withLock {
            queue.removeAll()
            primed = false
            remotePeakRMS = 0
            sinceRemote = .infinity
        }
    }

    /// Sample-wise sum of two PCM16 buffers of one length, clamped (nil `a`: `b` alone).
    static func sum(_ a: Data?, _ b: Data) -> Data {
        guard let a else { return b }
        var out = Data(count: b.count)
        a.withUnsafeBytes { ra in
            b.withUnsafeBytes { rb in
                out.withUnsafeMutableBytes { ro in
                    let x = ra.bindMemory(to: Int16.self), y = rb.bindMemory(to: Int16.self), o = ro.bindMemory(to: Int16.self)
                    for i in 0..<min(x.count, y.count) {
                        let s = Int32(Int16(littleEndian: x[i])) + Int32(Int16(littleEndian: y[i]))
                        o[i] = Int16(clamping: s).littleEndian
                    }
                }
            }
        }
        return out
    }
}

/// The call side of a recording: a `SystemAudioTap` converted to 16 kHz mono and pushed into the mixer.
public final class CallAudioCapture: @unchecked Sendable {
    private let tap: SystemAudioTap
    private let lock = NSLock()
    private var converter: PCMConverter?
    private var format: AVAudioFormat?
    private var running = false
    /// Call audio seconds received, and how much of it was not digital silence (a tap without permission delivers
    /// zeros): the "no call audio yet" notice.
    private var received: TimeInterval = 0
    private var heard = false
    /// Bumped by every start and stop: a start that returns after a stop undoes itself.
    private var generation = 0

    public let mixer: CallAudioMixer

    public init(tap: SystemAudioTap, mixer: CallAudioMixer = CallAudioMixer()) {
        self.tap = tap
        self.mixer = mixer
    }

    public var kind: CallAudioKind { tap.kind }
    public var isRunning: Bool { lock.withLock { running } }
    /// Some call audio was not digital silence since `start`.
    public var hasHeardAudio: Bool { lock.withLock { heard } }

    public func start(app: CallAudioApp?) throws {
        stop()
        mixer.reset()
        let mine = lock.withLock { () -> Int in
            running = true; received = 0; heard = false; converter = nil; format = nil
            generation += 1
            return generation
        }
        do {
            try tap.start(app: app) { [weak self] buffer in self?.handle(buffer) }
        } catch {
            lock.withLock { if generation == mine { running = false } }
            throw error
        }
        if lock.withLock({ generation != mine }) { tap.stop() }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let frames: [Data] = lock.withLock {
            guard running else { return [] }
            if format != buffer.format {
                format = buffer.format
                converter = PCMConverter(from: buffer.format)
            }
            return converter?.frames(from: buffer) ?? []
        }
        for frame in frames {
            let level = Level(pcm16: frame)
            lock.withLock {
                received += Double(frame.count / 2) / PCMConverter.sampleRate
                if level.peak > 0 { heard = true }
            }
            mixer.pushRemote(frame)
        }
    }

    public func stop() {
        let was = lock.withLock { () -> Bool in defer { running = false; converter = nil; format = nil; generation += 1 }; return running }
        if was { tap.stop() }
    }
}

/// Speaker labels for a call recording: the microphone side is "You" (`SpeakerRoster.youSlot`) wherever its voice is
/// heard and is not the call's echo, and the call side alone goes to the diarizer, whose slots number the remote
/// people. A plain mixed frame (no call audio) goes to the diarizer as before.
public final class CallSpeakers: SpeakerDiarizing, @unchecked Sendable {
    /// The microphone counts as speech from this RMS (a voice near the Mac, not the room's hum)…
    public static let youRMS: Float = 0.012
    /// …a "You" span stays open over pauses this short…
    public static let youHangover: TimeInterval = 0.4
    /// …and shorter spans (a cough, a click) are dropped.
    public static let youMinimum: TimeInterval = 0.25

    public let remote: SpeakerDiarizing
    private let lock = NSLock()
    private var spans: [SpeakerSpan] = []
    private var open: (start: TimeInterval, lastVoice: TimeInterval)?
    private var fedThrough: TimeInterval = 0

    public init(remote: SpeakerDiarizing) { self.remote = remote }

    public func feed(_ pcm16: Data, at documentTime: TimeInterval) { remote.feed(pcm16, at: documentTime) }

    public func feed(_ frame: CallFrame, at documentTime: TimeInterval) {
        remote.feed(frame.remote, at: documentTime)
        let end = documentTime + Double(frame.mic.count / 2) / PCMConverter.sampleRate
        let voice = !frame.micIsEcho && frame.micLevel.rms >= Self.youRMS
        lock.withLock {
            fedThrough = max(fedThrough, end)
            if voice {
                if let o = open, documentTime - o.lastVoice <= Self.youHangover {
                    open = (o.start, end)
                } else {
                    close()
                    open = (documentTime, end)
                }
            } else if let o = open, end - o.lastVoice > Self.youHangover {
                close()
            }
        }
    }

    /// Ends the open "You" span (under the lock).
    private func close() {
        guard let o = open else { return }
        open = nil
        if o.lastVoice - o.start >= Self.youMinimum {
            spans.append(SpeakerSpan(slot: SpeakerRoster.youSlot, start: o.start, end: o.lastVoice))
        }
        let horizon = fedThrough - SpeakerTimeline.retained
        if let first = spans.first, first.end < horizon { spans.removeAll { $0.end < horizon } }
    }

    public func flush() async {
        lock.withLock { close() }
        await remote.flush()
    }

    public var snapshot: SpeakerTimeline {
        let theirs = remote.snapshot
        return lock.withLock {
            let settled = open.map { $0.start } ?? max(0, fedThrough - Self.youHangover)
            var tentative = theirs.tentative
            if let o = open { tentative.append(SpeakerSpan(slot: SpeakerRoster.youSlot, start: o.start, end: o.lastVoice)) }
            let closed = (theirs.spans + spans).sorted { $0.start < $1.start }
            return SpeakerTimeline(spans: closed, finalizedThrough: min(theirs.finalizedThrough, settled), tentative: tentative)
        }
    }

    public func reset() {
        lock.withLock { spans = []; open = nil; fedThrough = 0 }
        remote.reset()
    }

    public func attachEmbedder(_ embedder: (any VoiceEmbedder)?) { remote.attachEmbedder(embedder) }
    public var voiceprints: [Int: Voiceprint] { remote.voiceprints }
    public func collectVoiceClips(_ enabled: Bool) { remote.collectVoiceClips(enabled) }
    public var voiceClips: [Int: Data] { remote.voiceClips }
}
