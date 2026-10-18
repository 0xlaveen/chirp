import AVFoundation
import ChirpCore
import Foundation

/// The coordinator is the sole owner; the tap uses a locked sink without an unbounded task queue.
@MainActor
protocol SessionAudio: AnyObject {
    func arm(onInterruption: @escaping @Sendable () -> Void) throws
    func begin(stream: StreamSession, onFailure: @escaping @Sendable () -> Void, onLimit: @escaping @Sendable () -> Void) throws
    func ready()
    func finish()
    func discard()
    func disarm()
}

enum SessionFailure: Error, LocalizedError, Equatable {
    case setup, permission, audio, connection, expired, cancelled, timeout, noResult, storage
    var errorDescription: String? {
        switch self {
        case .setup: "Open Chirp to pair your Mac and start a session."
        case .permission: "Open Chirp and allow microphone access in Settings."
        case .audio: "Microphone unavailable. Open Chirp to start again."
        case .connection: "Connection failed. Check Tailscale and your Mac."
        case .expired: "Session ended. Open Chirp to start again."
        case .cancelled: "Dictation cancelled."
        case .timeout: "The Mac did not finish in time."
        case .noResult: "Didn't catch that."
        case .storage: "Protected storage unavailable. Unlock and reopen Chirp."
        }
    }
}

@MainActor
final class MicrophoneCapture: SessionAudio {
    private let engine = AVAudioEngine()
    private let sink = CaptureSink()
    private var tapped = false
    private var observer: NSObjectProtocol?

    func arm(onInterruption: @escaping @Sendable () -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw SessionFailure.audio }
            sink.configure(format: format)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [sink] buffer, _ in
                sink.receive(buffer)
            }
            tapped = true
            engine.prepare()
            try engine.start()
            // Register after startup so startup configuration notifications cannot end the new session.
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                object: engine, queue: .main) { _ in onInterruption() }
        } catch {
            disarm()
            throw SessionFailure.audio
        }
    }

    func begin(stream: StreamSession, onFailure: @escaping @Sendable () -> Void, onLimit: @escaping @Sendable () -> Void) throws {
        try sink.begin(stream, onFailure: onFailure, onLimit: onLimit)
    }
    func ready() { sink.ready() }
    func finish() { sink.finish() }
    func discard() { sink.discard() }
    func disarm() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        sink.discard()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

final class CaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var converter: PCMConverter?
    private var stream: StreamSession?
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var isReady = false
    private var ending = false
    private var failed = false
    private var failure: (@Sendable () -> Void)?
    private var limit: (@Sendable () -> Void)?
    private var reachedLimit = false
    private var queuedBytes = 0
    private let maxPreReadyBytes = 64 * 1024
    // Reserve 200ms for flush below StreamSession's hard 120s byte limit.
    private let maxCaptureBytes = 1198 * 3_200

    func configure(format: AVAudioFormat) {
        lock.withLock { self.format = format }
    }
    func begin(_ stream: StreamSession, onFailure: @escaping @Sendable () -> Void, onLimit: @escaping @Sendable () -> Void) throws {
        try lock.withLock {
            guard let format, let converter = PCMConverter(from: format) else { throw SessionFailure.audio }
            self.converter = converter
            self.stream = stream
            failure = onFailure; limit = onLimit
            pending.removeAll(); pendingBytes = 0; isReady = false; ending = false; failed = false
            reachedLimit = false; queuedBytes = 0
        }
    }
    func receive(_ buffer: AVAudioPCMBuffer) {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            // Armed idle capture is immediately discarded: no conversion, buffering, file or network writes.
            guard stream != nil, !ending, !failed, !reachedLimit, let converter else { return nil }
            for frame in converter.frames(from: buffer) { enqueue(frame) }
            return failed ? failure : reachedLimit ? limit : nil
        }
        notify?()
    }
    private func enqueue(_ data: Data, flushing: Bool = false) {
        guard !failed, flushing || !reachedLimit else { return }
        let available = (flushing ? 120 * 32_000 : maxCaptureBytes) - queuedBytes
        let data = Data(data.prefix(available))
        guard !data.isEmpty else { return }
        queuedBytes += data.count
        if queuedBytes >= maxCaptureBytes { reachedLimit = true }
        if isReady {
            if stream?.sendAudio(data) != true { failed = true }
        } else if pendingBytes + data.count <= maxPreReadyBytes {
            pending.append(data); pendingBytes += data.count
        } else { failed = true; pending.removeAll(); pendingBytes = 0 }
    }
    func ready() {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !isReady, !failed else { return failed ? failure : nil }
            isReady = true
            for data in pending where !failed { if stream?.sendAudio(data) != true { failed = true } }
            pending.removeAll(); pendingBytes = 0
            return failed ? failure : nil
        }
        notify?()
    }
    func finish() {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !ending else { return nil }
            ending = true
            if var tail = converter?.flush() {
                if tail.count < 640 { tail.append(Data(count: 640 - tail.count)) }
                enqueue(tail, flushing: true)
            }
            converter = nil
            return failed ? failure : nil
        }
        notify?()
    }
    func discard() {
        lock.withLock {
            stream = nil; converter = nil; pending.removeAll(); pendingBytes = 0
            isReady = false; ending = true; reachedLimit = false; queuedBytes = 0
            failure = nil; limit = nil
        }
    }
}
