import Foundation
import Testing
@testable import ChirpCore

/// A transport that can stall: with `stalled` set, `send` never completes (until the socket is cancelled) and
/// `receive` waits for the script. No sockets.
final class FakeTransport: StreamTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [CheckedContinuation<Void, Error>] = []
    private var _sent: [URLSessionWebSocketTask.Message] = []
    private var _cancelled = false
    private var pendingReceive: [URLSessionWebSocketTask.Message]
    let stalled: Bool

    init(stalled: Bool, incoming: [String] = []) {
        self.stalled = stalled
        pendingReceive = incoming.map { .string($0) }
    }

    var sent: [URLSessionWebSocketTask.Message] { lock.withLock { _sent } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    func resume() {}

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock { _sent.append(message) }
        if stalled { try await park() }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if let next = lock.withLock({ pendingReceive.isEmpty ? nil : pendingReceive.removeFirst() }) { return next }
        try await park()
        throw URLError(.cancelled)
    }

    func cancel(with code: URLSessionWebSocketTask.CloseCode) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            _cancelled = true
            defer { parked.removeAll() }
            return parked
        }
        for w in waiting { w.resume(throwing: URLError(.cancelled)) }
    }

    private func park() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let already = lock.withLock { () -> Bool in
                if _cancelled { return true }
                parked.append(c)
                return false
            }
            if already { c.resume(throwing: URLError(.cancelled)) }
        }
    }
}

/// The reason of the first `.closed` event.
private func closeReason(_ session: StreamSession) async -> String? {
    for await event in session.events { if case .closed(let reason) = event { return reason } }
    return nil
}

private let frame = Data(count: PCMConverter.frameBytes)
private let ready = #"{"type":"ready","session":"s1","engine":"fake","debug_retention":false}"#

@Suite struct StreamBoundsTests {
    private func limits(queued: Int = 512 * 1024, audio: Int = 120 * 32_000,
                        deadline: Duration = .seconds(3600), grace: Duration = .milliseconds(20)) -> StreamLimits {
        var l = StreamLimits()
        l.maxQueuedBytes = queued; l.maxAudioBytes = audio; l.readyDeadline = deadline; l.cancelGrace = grace
        return l
    }

    @Test(.timeLimit(.minutes(1))) func aStalledSocketOverflowsTheQueueWithAnExplicitError() async {
        let transport = FakeTransport(stalled: true)
        let session = StreamSession(transport: transport, options: StartOptions(), limits: limits(queued: 10 * frame.count))
        await session.open()
        var accepted = 0
        for _ in 0..<50 where session.sendAudio(frame) { accepted += 1 }
        #expect(accepted <= 11)                          // bounded: the pump holds at most one frame in flight
        #expect(await closeReason(session) == "Connection too slow — audio was not sent")
        #expect(transport.cancelled)
        #expect(!session.sendAudio(frame))               // nothing more is queued after the failure
    }

    @Test(.timeLimit(.minutes(1))) func aDrainingSocketNeverOverflows() async {
        let transport = FakeTransport(stalled: false, incoming: [ready])
        let session = StreamSession(transport: transport, options: StartOptions(), limits: limits(queued: 4 * frame.count))
        await session.open()
        for _ in 0..<200 {
            #expect(session.sendAudio(frame))
            await Task.yield()                           // the capture thread paces at 50 ms; the pump keeps up
            try? await Task.sleep(for: .milliseconds(1))
        }
        await session.close()
    }

    @Test(.timeLimit(.minutes(1))) func anUtteranceOverTheLocalCapIsRefused() async {
        let transport = FakeTransport(stalled: false, incoming: [ready])
        let session = StreamSession(transport: transport, options: StartOptions(), limits: limits(audio: 5 * frame.count))
        await session.open()
        var accepted = 0
        for _ in 0..<10 where session.sendAudio(frame) { accepted += 1; try? await Task.sleep(for: .milliseconds(2)) }
        #expect(accepted == 5)
        #expect(await closeReason(session) == "Utterance too long")
    }

    @Test(.timeLimit(.minutes(1))) func aServerThatNeverSaysReadyTimesOut() async {
        let transport = FakeTransport(stalled: true)
        // Injected clock: the deadline elapses immediately.
        let session = StreamSession(transport: transport, options: StartOptions(), limits: limits(deadline: .seconds(10)),
                                    sleep: { _ in })
        await session.open()
        #expect(await closeReason(session) == "Server did not answer in time")
        #expect(transport.cancelled)
    }

    @Test(.timeLimit(.minutes(1))) func readyBeforeTheDeadlineKeepsTheSessionOpen() async {
        let transport = FakeTransport(stalled: false, incoming: [ready])
        let session = StreamSession(transport: transport, options: StartOptions(), limits: limits(deadline: .milliseconds(150)))
        await session.open()
        var sawReady = false
        for await event in session.events {
            if case .message(.ready) = event { sawReady = true; break }
        }
        #expect(sawReady)
        try? await Task.sleep(for: .milliseconds(400))   // well past the deadline
        #expect(!transport.cancelled)
        await session.close()
    }

    @Test(.timeLimit(.minutes(1))) func cancelClosesPromptlyEvenIfTheCancelFrameNeverCompletes() async {
        let transport = FakeTransport(stalled: true, incoming: [ready])
        let session = StreamSession(transport: transport, options: StartOptions(), limits: limits(grace: .milliseconds(20)))
        await session.open()
        let started = ContinuousClock.now
        await session.cancel()
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(transport.cancelled)
        #expect(await closeReason(session) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func cancelWithAnInjectedClockDoesNotWaitAtAll() async {
        let transport = FakeTransport(stalled: true)
        let session = StreamSession(transport: transport, options: StartOptions(), limits: limits(deadline: .seconds(3600)),
                                    sleep: { d in if d < .seconds(60) { return }; try? await Task.sleep(for: d) })
        await session.open()
        await session.cancel()
        #expect(transport.cancelled)
    }
}
