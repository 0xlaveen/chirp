import Foundation

public enum StreamEvent: Sendable, Equatable {
    case message(ServerMessage)
    /// The socket ended. `reason` is nil for a deliberate close.
    case closed(reason: String?)
}

/// The WebSocket under a `StreamSession`, so tests can inject a transport that stalls or never completes.
public protocol StreamTransport: Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with code: URLSessionWebSocketTask.CloseCode)
}

struct URLSessionTransport: StreamTransport {
    let task: URLSessionWebSocketTask
    func resume() { task.resume() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func cancel(with code: URLSessionWebSocketTask.CloseCode) { task.cancel(with: code, reason: nil) }
}

/// Local bounds that protect memory and the microphone when the socket stalls; the server's own limits only
/// apply to audio it has already received.
public struct StreamLimits: Sendable {
    /// Audio queued but not yet written to the socket (about 16 s of PCM16 at 16 kHz).
    public var maxQueuedBytes = 512 * 1024
    /// One utterance, matching the server's 120 s cap.
    public var maxAudioBytes = 120 * 16_000 * 2
    /// How long the server may take to answer `start` with `ready`.
    public var readyDeadline: Duration = .seconds(10)
    /// How long `cancel` waits for the cancel frame to be written before closing anyway.
    public var cancelGrace: Duration = .milliseconds(300)

    public init() {}
}

/// Why `sendAudio` stopped accepting frames.
enum AudioGateTrip { case overflow, tooLong }

/// Counts queued and total audio bytes from the capture thread, so the bounds hold without waiting on the actor.
final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: StreamLimits
    private var queued = 0, total = 0
    private var tripped = false

    init(_ limits: StreamLimits) { self.limits = limits }

    /// Returns nil to accept the frame, or the reason the session must fail. After a trip every frame is refused.
    func admit(_ bytes: Int) -> (accepted: Bool, trip: AudioGateTrip?) {
        lock.withLock {
            guard !tripped else { return (false, nil) }
            if total + bytes > limits.maxAudioBytes { tripped = true; return (false, .tooLong) }
            if queued + bytes > limits.maxQueuedBytes { tripped = true; return (false, .overflow) }
            queued += bytes
            total += bytes
            return (true, nil)
        }
    }

    func written(_ bytes: Int) { lock.withLock { queued = max(0, queued - bytes) } }
}

/// One utterance over `WS /v1/stream`. Audio goes through an ordered, bounded queue, so `stop`
/// is always sent after the last frame. Nothing is logged or written to disk.
public actor StreamSession {
    public nonisolated let events: AsyncStream<StreamEvent>
    private let eventsOut: AsyncStream<StreamEvent>.Continuation
    private nonisolated let audioIn: AsyncStream<Data>.Continuation
    private let audioStream: AsyncStream<Data>
    private nonisolated let gate: AudioGate
    private let transport: StreamTransport
    private let options: StartOptions
    private let limits: StreamLimits
    private let sleep: @Sendable (Duration) async -> Void
    private var pump: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var readyDeadline: Task<Void, Never>?
    private var closing = false

    public init(transport: StreamTransport, options: StartOptions, limits: StreamLimits = StreamLimits(),
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.transport = transport
        self.options = options
        self.limits = limits
        self.sleep = sleep
        gate = AudioGate(limits)
        (events, eventsOut) = AsyncStream.makeStream(of: StreamEvent.self)
        (audioStream, audioIn) = AsyncStream.makeStream(of: Data.self)
    }

    public init(config: ServerConfig, options: StartOptions, urlSession: URLSession = .shared) {
        let request = config.authorized(URLRequest(url: config.streamURL))
        let task = urlSession.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        self.init(transport: URLSessionTransport(task: task), options: options)
    }

    /// Connects, sends `start`, and begins relaying server messages and queued audio.
    public func open() {
        transport.resume()
        let transport = self.transport
        let start = ClientMessage.start(options)
        let audio = audioStream
        let gate = self.gate
        pump = Task { [weak self] in
            do {
                try await transport.send(.string(start))
                for await frame in audio {
                    try await transport.send(.data(frame))
                    gate.written(frame.count)
                }
            } catch {
                await self?.fail(error)
            }
        }
        receiver = Task { [weak self] in
            while true {
                do {
                    let message = try await transport.receive()
                    guard let self else { return }
                    let data: Data
                    switch message {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: continue
                    }
                    if let parsed = try? ServerMessage.decode(data) {
                        if case .ready = parsed { await self.markReady() }
                        await self.emit(.message(parsed))
                    }
                } catch {
                    await self?.fail(error)
                    return
                }
            }
        }
        let (deadline, sleep) = (limits.readyDeadline, self.sleep)
        readyDeadline = Task { [weak self] in
            await sleep(deadline)
            guard !Task.isCancelled else { return }
            await self?.abort(reason: "Server did not answer in time")
        }
    }

    private func markReady() {
        readyDeadline?.cancel()
        readyDeadline = nil
    }

    /// Queue one PCM16 frame. Safe to call from any thread; order is preserved. Returns false once the session has
    /// refused audio: past the 120 s cap or with too much unsent audio, which fails the session and so stops capture.
    @discardableResult
    public nonisolated func sendAudio(_ frame: Data) -> Bool {
        let (accepted, trip) = gate.admit(frame.count)
        if accepted { audioIn.yield(frame) }
        if let trip {
            let reason = trip == .tooLong ? "Utterance too long" : "Connection too slow — audio was not sent"
            Task { await self.abort(reason: reason) }
        }
        return accepted
    }

    /// Finalize: flush queued audio, then ask for the final transcript.
    public func stop() async {
        audioIn.finish()
        await pump?.value
        try? await transport.send(.string(ClientMessage.stop))
    }

    /// Discard: no final will be produced. The cancel frame is best effort: a transport that stopped draining
    /// must not hold teardown (and the microphone) hostage, so the socket is closed after `cancelGrace` at the latest.
    public func cancel() async {
        audioIn.finish()
        pump?.cancel()
        let (done, signal) = AsyncStream.makeStream(of: Void.self)
        let (transport, grace, sleep) = (self.transport, limits.cancelGrace, self.sleep)
        Task { try? await transport.send(.string(ClientMessage.cancel)); signal.yield() }
        Task { await sleep(grace); signal.yield() }
        for await _ in done { break }
        close()
    }

    public func close() {
        guard !closing else { return }
        closing = true
        audioIn.finish()
        pump?.cancel()
        readyDeadline?.cancel()
        transport.cancel(with: .normalClosure)
        receiver?.cancel()
        eventsOut.yield(.closed(reason: nil))
        eventsOut.finish()
    }

    private func emit(_ event: StreamEvent) { if !closing { eventsOut.yield(event) } }

    private func fail(_ error: Error) { abort(reason: Self.describe(error)) }

    /// Ends the session with a reason the HUD shows.
    private func abort(reason: String) {
        guard !closing else { return }
        closing = true
        audioIn.finish()
        pump?.cancel()
        receiver?.cancel()
        readyDeadline?.cancel()
        transport.cancel(with: .goingAway)
        eventsOut.yield(.closed(reason: reason))
        eventsOut.finish()
    }

    static func describe(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == NSURLErrorDomain {
            switch e.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                 NSURLErrorNotConnectedToInternet:
                return "Server unreachable"
            case NSURLErrorBadServerResponse: return "Server rejected the connection (check the token)"
            default: break
            }
        }
        return "Connection lost"
    }
}
