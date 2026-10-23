import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Live Notes' silence watch on its own clock (the audio it is fed): a mute warns, signal clears the warning, and
/// 15 min of digital zeros asks for a pause, once.
@MainActor
@Suite struct NotesCaptureSinkTests {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [NotesSilenceEvent] = []
        var all: [NotesSilenceEvent] { lock.withLock { _all } }
        func add(_ e: NotesSilenceEvent) { lock.withLock { _all.append(e) } }
    }

    private let zero = Data(count: 1600)
    private let tone = Data((0..<800).flatMap { i -> [UInt8] in
        let v = Int16(8000 * sin(Double(i) * 0.12))
        return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
    })

    private func recorder() -> NotesRecorder {
        NotesRecorder(makeSession: { StreamSession(transport: NeverTransport(), options: $0) },
                      structure: { _ in throw NotesStructureError.unsupported(404) }, options: StartOptions(), structuring: false)
    }

    /// Feeds `seconds` of 50 ms frames.
    private func feed(_ sink: NotesCaptureSink, _ frame: Data, _ seconds: Double) {
        for _ in 0..<Int((seconds * 20).rounded()) { sink.handle(frame) }
    }

    @Test func fifteenMinutesOfDigitalZerosWarnsThenPausesOnce() {
        let events = Events()
        let sink = NotesCaptureSink(recorder: recorder()) { events.add($0) }
        feed(sink, tone, 2)
        feed(sink, zero, 2)
        #expect(events.all == [.started])
        feed(sink, zero, NotesCaptureSink.pauseAfter - 5)
        #expect(events.all == [.started])
        feed(sink, zero, 5)
        #expect(events.all == [.started, .long])
        feed(sink, zero, 60)
        #expect(events.all == [.started, .long])
        feed(sink, tone, 0.05)
        #expect(events.all == [.started, .long, .ended])
    }

    @Test func aShortMuteWarnsAndSignalClearsIt() {
        let events = Events()
        let sink = NotesCaptureSink(recorder: recorder()) { events.add($0) }
        feed(sink, zero, 1)
        #expect(events.all.isEmpty)
        feed(sink, zero, 1)
        feed(sink, tone, 1)
        feed(sink, zero, 1)
        #expect(events.all == [.started, .ended])
    }
}

/// A transport that never connects (the sink tests route no audio anywhere).
private struct NeverTransport: StreamTransport {
    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {}
    func receive() async throws -> URLSessionWebSocketTask.Message { try await Task.sleep(for: .seconds(3600)); throw URLError(.cancelled) }
    func cancel(with code: URLSessionWebSocketTask.CloseCode) {}
}
