import Foundation

public enum StreamEvent: Sendable, Equatable {
    case message(ServerMessage)
    /// The socket ended. `reason` is nil for a deliberate close.
    case closed(reason: String?)
}

/// One utterance over `WS /v1/stream`. Audio goes through an ordered queue, so `stop`
/// is always sent after the last frame. Nothing is logged or written to disk.
public actor StreamSession {
    public nonisolated let events: AsyncStream<StreamEvent>
    private let eventsOut: AsyncStream<StreamEvent>.Continuation
    private nonisolated let audioIn: AsyncStream<Data>.Continuation
    private let audioStream: AsyncStream<Data>
    private let socket: URLSessionWebSocketTask
    private let options: StartOptions
    private var pump: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var closing = false

    public init(config: ServerConfig, options: StartOptions, urlSession: URLSession = .shared) {
        let request = config.authorized(URLRequest(url: config.streamURL))
        socket = urlSession.webSocketTask(with: request)
        socket.maximumMessageSize = 1 << 20
        self.options = options
        (events, eventsOut) = AsyncStream.makeStream(of: StreamEvent.self)
        (audioStream, audioIn) = AsyncStream.makeStream(of: Data.self)
    }

    /// Connects, sends `start`, and begins relaying server messages and queued audio.
    public func open() {
        socket.resume()
        let socket = self.socket
        let start = ClientMessage.start(options)
        let audio = audioStream
        pump = Task { [weak self] in
            do {
                try await socket.send(.string(start))
                for await frame in audio { try await socket.send(.data(frame)) }
            } catch {
                await self?.fail(error)
            }
        }
        receiver = Task { [weak self] in
            while true {
                do {
                    let message = try await socket.receive()
                    guard let self else { return }
                    let data: Data
                    switch message {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: continue
                    }
                    if let parsed = try? ServerMessage.decode(data) { await self.emit(.message(parsed)) }
                } catch {
                    await self?.fail(error)
                    return
                }
            }
        }
    }

    /// Queue one PCM16 frame. Safe to call from any thread; order is preserved.
    public nonisolated func sendAudio(_ frame: Data) { audioIn.yield(frame) }

    /// Finalize: flush queued audio, then ask for the final transcript.
    public func stop() async {
        audioIn.finish()
        await pump?.value
        try? await socket.send(.string(ClientMessage.stop))
    }

    /// Discard: no final will be produced.
    public func cancel() async {
        audioIn.finish()
        pump?.cancel()
        try? await socket.send(.string(ClientMessage.cancel))
        close()
    }

    public func close() {
        guard !closing else { return }
        closing = true
        audioIn.finish()
        pump?.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
        receiver?.cancel()
        eventsOut.yield(.closed(reason: nil))
        eventsOut.finish()
    }

    private func emit(_ event: StreamEvent) { if !closing { eventsOut.yield(event) } }

    private func fail(_ error: Error) {
        guard !closing else { return }
        closing = true
        audioIn.finish()
        pump?.cancel()
        receiver?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        eventsOut.yield(.closed(reason: Self.describe(error)))
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
