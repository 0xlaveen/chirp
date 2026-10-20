import Foundation
import Testing
@testable import ChirpCore

/// Time that moves only when the test says so: `sleep` returns once `advance` has passed its deadline.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 0
    private var sleepers: [(until: Double, resume: CheckedContinuation<Void, Never>)] = []

    var now: Double { lock.withLock { time } }

    func sleep(_ d: Duration) async {
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if seconds <= 0 { return true }
                sleepers.append((time + seconds, c))
                return false
            }
            if ready { c.resume() }
        }
    }

    func advance(_ seconds: Double) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            time += seconds
            let due = sleepers.filter { $0.until <= time }.map(\.resume)
            sleepers.removeAll { $0.until <= time }
            return due
        }
        for c in due { c.resume() }
    }
}

/// A scripted structuring backend: records every request, can hold passes until released, and counts overlap.
final class StructureStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [NotesStructureRequest] = []
    private var running = 0
    private var _maxRunning = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    var hold = false
    var reply: @Sendable (NotesStructureRequest) throws -> NotesStructureResponse = { r in
        NotesStructureResponse(markdown: "## Notes\n- \(r.transcript.split(separator: "\n").count) segments", structured: true)
    }

    var requests: [NotesStructureRequest] { lock.withLock { _requests } }
    var maxRunning: Int { lock.withLock { _maxRunning } }

    func call(_ r: NotesStructureRequest) async throws -> NotesStructureResponse {
        let shouldHold = lock.withLock { () -> Bool in
            _requests.append(r)
            running += 1
            _maxRunning = max(_maxRunning, running)
            return hold
        }
        if shouldHold { await withCheckedContinuation { c in lock.withLock { held.append(c) } } }
        defer { lock.withLock { running -= 1 } }
        return try reply(r)
    }

    /// Lets every held pass finish.
    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            hold = false
            defer { held.removeAll() }
            return held
        }
        for c in waiting { c.resume() }
    }
}

@MainActor
@Suite(.serialized) struct NotesRecorderTests {
    private let frame = Data(count: 1600)
    private let speech = Level(peak: 0.5, rms: 0.2)

    private func make(_ server: MockServer, port: UInt16, stub: StructureStub, clock: ManualClock,
                      health: Health? = Health(correction: "available", notesStructure: true)) -> NotesRecorder {
        let config = ServerConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        return NotesRecorder(makeSession: { StreamSession(config: config, options: $0) },
                             structure: { try await stub.call($0) },
                             now: { clock.now }, sleep: { await clock.sleep($0) },
                             options: StartOptions(client: "mac", correction: true), structuring: true, health: health)
    }

    /// Polls until `condition` holds. The limit is generous because other suites (the snapshot renderer) can hold
    /// the main actor for seconds in a full run; a passing check returns as soon as the condition is true.
    private func eventually(_ what: String = "condition", within seconds: Double = 60,
                            _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func send(_ r: NotesRecorder, frames n: Int) {
        for _ in 0..<n { r.handleFrame(frame, level: speech) }
    }

    private func started(_ server: MockServer) async throws -> (MockServer, UInt16) {
        let port = try await server.start()
        server.numberedFinals = true
        return (server, port)
    }

    @Test func framesBeforeAndAfterACutLandOnTheirSockets() async throws {
        let (server, port) = try await started(try MockServer())
        defer { server.stop() }
        let stub = StructureStub(), clock = ManualClock()
        let r = make(server, port: port, stub: stub, clock: clock)
        r.start()
        await eventually("ready") { r.state == .recording }
        send(r, frames: 4)
        await r.cut()
        send(r, frames: 6)
        await r.stop()
        #expect(server.bytesBySocket == [0: 4 * 1600, 1: 6 * 1600])
        #expect(r.document.segments.map(\.text) == ["Segment 0.", "Segment 1."])
        #expect(r.document.segments[1].offset == 0.2)                    // 4 × 50 ms before the cut
        #expect(r.state == .stopped && r.elapsed == 0.5)
    }

    @Test func oldSegmentCorrectionOverlapsNewCapture() async throws {
        let (server, port) = try await started(try MockServer())
        defer { server.stop() }
        server.script(0, .init(correcting: true, finalDelay: 2.0))
        let stub = StructureStub(), clock = ManualClock()
        let r = make(server, port: port, stub: stub, clock: clock)
        r.start()
        await eventually("ready") { r.state == .recording }
        send(r, frames: 2)
        await r.cut()
        await eventually("old segment correcting") { r.correctingCount == 1 }
        send(r, frames: 3)
        await eventually("new audio while the old one corrects") { server.bytesBySocket[1] == 3 * 1600 }
        #expect(r.correctingCount == 1 && r.document.segments.isEmpty)
        await eventually("old final") { r.document.segments.count == 1 }
        await r.stop()
        #expect(r.document.segments.map(\.text) == ["Segment 0.", "Segment 1."])
    }

    @Test func finalsAppendInOrderWhenTheSecondArrivesFirst() async throws {
        let (server, port) = try await started(try MockServer())
        defer { server.stop() }
        server.script(0, .init(finalDelay: 2.0))
        let stub = StructureStub(), clock = ManualClock()
        let r = make(server, port: port, stub: stub, clock: clock)
        r.start()
        await eventually("ready") { r.state == .recording }
        send(r, frames: 2)
        await r.cut()
        send(r, frames: 2)
        await r.cut()
        try await Task.sleep(for: .milliseconds(250))
        #expect(r.document.segments.isEmpty)       // segment 1 is final, but waits for segment 0
        send(r, frames: 2)
        await r.stop()
        #expect(r.document.segments.map(\.text) == ["Segment 0.", "Segment 1.", "Segment 2."])
        #expect(r.document.segments.map(\.id) == [0, 1, 2])
    }

    @Test func schedulerWaitsForCorrectionsAndNeverOverlaps() async throws {
        let (server, port) = try await started(try MockServer())
        defer { server.stop() }
        server.script(0, .init(finalDelay: 0.4))
        server.script(1, .init(correcting: true, finalDelay: 3.0))
        let stub = StructureStub(), clock = ManualClock()
        let r = make(server, port: port, stub: stub, clock: clock)
        r.start()
        await eventually("ready") { r.state == .recording }
        send(r, frames: 2)
        await r.cut()
        send(r, frames: 2)
        await r.cut()
        await eventually("segment 0 committed") { r.document.segments.count == 1 }
        // Segment 1 is still being corrected: no pass yet.
        #expect(r.correctingCount == 1 && stub.requests.isEmpty)
        await eventually("segment 1 committed") { r.document.segments.count == 2 }
        await eventually("one pass") { stub.requests.count == 1 }
        #expect(stub.requests[0].transcript == "Segment 0.\nSegment 1.")
        #expect(stub.maxRunning == 1)
        await r.stop()
    }

    @Test func schedulerCoalescesAndRespectsMinInterval() async throws {
        let (server, port) = try await started(try MockServer())
        defer { server.stop() }
        let stub = StructureStub(), clock = ManualClock()
        stub.hold = true
        let r = make(server, port: port, stub: stub, clock: clock)
        r.start()
        await eventually("ready") { r.state == .recording }
        send(r, frames: 2)
        await r.cut()
        await eventually("first pass") { stub.requests.count == 1 }
        #expect(r.passInFlight && r.structuring == .running)
        // Two more finals while the pass runs: remembered, not started.
        for _ in 0..<2 {
            send(r, frames: 2)
            await r.cut()
        }
        await eventually("finals committed") { r.document.segments.count == 3 }
        #expect(stub.requests.count == 1)
        stub.release()
        await eventually("pass finished") { !r.passInFlight }
        // The pending pass waits out the interval since the last one ended.
        try await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.count == 1)
        clock.advance(NotesRecorder.minInterval - 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.count == 1)
        clock.advance(1)
        await eventually("coalesced second pass") { stub.requests.count == 2 }
        #expect(stub.requests[1].transcript == "Segment 0.\nSegment 1.\nSegment 2.")
        #expect(stub.maxRunning == 1)
        await r.stop()
    }

    @Test func stopRunsOneFinalPassThenFreezes() async throws {
        let (server, port) = try await started(try MockServer())
        defer { server.stop() }
        let stub = StructureStub(), clock = ManualClock()
        let r = make(server, port: port, stub: stub, clock: clock)
        r.start()
        await eventually("ready") { r.state == .recording }
        send(r, frames: 3)
        await r.stop()
        #expect(stub.requests.map(\.final) == [true])
        #expect(r.document.frozen.map(\.markdown) == ["## Notes\n- 1 segments"])
        #expect(r.document.openBlock == nil && r.document.livePartial.isEmpty)
        #expect(r.state == .stopped && r.document.isDirty)
        // Record again continues the same document.
        r.start()
        await eventually("ready again") { r.state == .recording }
        send(r, frames: 2)
        await r.stop()
        #expect(r.document.segments.count == 2 && r.document.frozen.count == 2)
        #expect(stub.requests.last?.outline == ["Notes"] && stub.requests.last?.transcript == "Segment 1.")
    }

    @Test func threeConsecutiveSegmentFailuresStopWithAnError() async throws {
        let (server, port) = try await started(try MockServer())
        defer { server.stop() }
        for i in 1...3 { server.script(i, .init(errorOnAudio: "engine")) }
        let stub = StructureStub(), clock = ManualClock()
        let r = make(server, port: port, stub: stub, clock: clock)
        r.start()
        await eventually("ready") { r.state == .recording }
        send(r, frames: 2)
        await r.cut()
        await eventually("segment 0 committed") { r.document.segments.count == 1 }
        let deadline = Date().addingTimeInterval(5)
        while r.state.isCapturing || r.state == .stopping, Date() < deadline {
            send(r, frames: 1)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(r.state == .error("Notes stopped: Speech engine hiccup"))
        #expect(r.document.segments.first?.text == "Segment 0.")
        #expect(r.document.segments.filter(\.isGap).count == 3)
        #expect(!r.document.isEmpty)
    }

    @Test func firstSocketThatCannotStartIsAnError() async throws {
        let (server, port) = try await started(try MockServer())
        defer { server.stop() }
        server.script(0, .init(refuse: "busy"))
        let stub = StructureStub(), clock = ManualClock()
        let r = make(server, port: port, stub: stub, clock: clock)
        r.start()
        await eventually("error") { if case .error = r.state { true } else { false } }
        #expect(r.state == .error("Server is busy") && r.document.segments.isEmpty)
    }

    @Test func structuringIsOffForAnOldServerAndAfterA409() async throws {
        let (server, port) = try await started(try MockServer())
        defer { server.stop() }
        let stub = StructureStub(), clock = ManualClock()
        let old = make(server, port: port, stub: stub, clock: clock, health: Health(correction: "available"))
        #expect(old.structuring == .off(.unsupported))
        let off = make(server, port: port, stub: stub, clock: clock, health: Health(correction: "off", notesStructure: true))
        #expect(off.structuring == .off(.correctionOff))
        old.start()
        await eventually("ready") { old.state == .recording }
        send(old, frames: 2)
        await old.stop()
        #expect(stub.requests.isEmpty && old.document.frozen.isEmpty && old.document.segments.count == 1)

        stub.reply = { _ in throw NotesStructureError.off }
        let r = make(server, port: port, stub: stub, clock: clock)
        #expect(r.structuring == .idle)
        r.start()
        await eventually("ready") { r.state == .recording }
        send(r, frames: 2)
        await r.cut()
        await eventually("409") { r.structuring == .off(.correctionOff) }
        send(r, frames: 2)
        await r.stop()
        #expect(stub.requests.count == 1)
    }

    @Test func unknownHealthNeverAllowsStructuring() {
        #expect(StructuringStatus.availability(health: nil, enabled: true) == .off(.waiting))
        let r = NotesRecorder(makeSession: { StreamSession(config: ServerConfig(), options: $0) },
                              structure: { _ in Issue.record("no pass may run"); return .failed("http") },
                              options: StartOptions(), structuring: true, health: nil)
        #expect(r.structuring == .off(.waiting))
        // A session with structuring switched off stays off when a health poll fails.
        r.configureStructuring(enabled: false, health: Health(correction: "available", notesStructure: true))
        #expect(r.structuring == .off(.disabled))
        r.configureStructuring(enabled: true, health: nil)
        #expect(r.structuring == .off(.waiting))
    }

    @Test func noPassWhileASegmentIsStillFinalizing() async throws {
        let (server, port) = try await started(try MockServer())
        defer { server.stop() }
        server.script(2, .init(finalDelay: 3.0))          // decoding, not yet `correcting`
        let stub = StructureStub(), clock = ManualClock()
        let r = make(server, port: port, stub: stub, clock: clock)
        r.start()
        await eventually("ready") { r.state == .recording }
        send(r, frames: 2)
        await r.cut()
        await eventually("first pass") { stub.requests.count == 1 && !r.passInFlight }
        // Segment 1's final lands inside minInterval: pending, timer armed.
        send(r, frames: 2)
        await r.cut()
        await eventually("segment 1 committed") { r.document.segments.count == 2 }
        // Segment 2 is cut and still finalizing when the timer fires: no pass may start.
        send(r, frames: 2)
        await r.cut()
        #expect(r.finalizingCount == 1)
        clock.advance(NotesRecorder.minInterval)
        try await Task.sleep(for: .milliseconds(150))
        #expect(stub.requests.count == 1)
        await eventually("segment 2 committed") { r.document.segments.count == 3 }
        await eventually("pass after the final") { stub.requests.count == 2 }
        #expect(stub.requests[1].transcript == "Segment 0.\nSegment 1.\nSegment 2.")
        await r.stop()
    }

    @Test func concurrentCutsOpenOneSocketAndKeepOrder() async throws {
        let (server, port) = try await started(try MockServer())
        defer { server.stop() }
        let stub = StructureStub(), clock = ManualClock()
        let r = make(server, port: port, stub: stub, clock: clock)
        r.start()
        await eventually("ready") { r.state == .recording }
        send(r, frames: 2)
        async let a: Void = r.cut()
        async let b: Void = r.cut()
        _ = await (a, b)
        send(r, frames: 2)
        await r.stop()
        #expect(server.started == 2)
        #expect(r.document.segments.map(\.text) == ["Segment 0.", "Segment 1."])
    }

    @Test func theTitleTimeIsTheFirstRecording() async throws {
        let (server, port) = try await started(try MockServer())
        defer { server.stop() }
        let stub = StructureStub(), clock = ManualClock()
        let r = make(server, port: port, stub: stub, clock: clock)
        let created = r.document.startedAt
        try await Task.sleep(for: .milliseconds(50))
        r.start()
        let first = r.document.startedAt
        #expect(first > created)
        await eventually("ready") { r.state == .recording }
        send(r, frames: 2)
        await r.stop()
        r.start()                                          // continuing the same notes keeps the first time
        #expect(r.document.startedAt == first)
        await eventually("ready again") { r.state == .recording }
        await r.stop()
    }

    @Test func aFailedPassKeepsTheBlockAndReportsTheCode() async throws {
        let (server, port) = try await started(try MockServer())
        defer { server.stop() }
        let stub = StructureStub(), clock = ManualClock()
        stub.reply = { _ in .failed("rejected") }
        let r = make(server, port: port, stub: stub, clock: clock)
        r.start()
        await eventually("ready") { r.state == .recording }
        send(r, frames: 2)
        await r.cut()
        await eventually("failed pass") { r.structuring == .failed("rejected") }
        #expect(r.document.openBlock == nil && r.document.unstructuredTail == "Segment 0.")
        await r.stop()
    }
}

@Suite struct NotesFrameRouterTests {
    private struct IdleTransport: StreamTransport {
        func resume() {}
        func send(_ message: URLSessionWebSocketTask.Message) async throws {}
        func receive() async throws -> URLSessionWebSocketTask.Message { try await Task.sleep(for: .seconds(60)); throw CancellationError() }
        func cancel(with code: URLSessionWebSocketTask.CloseCode) {}
    }

    @Test func asksForOneCutAtThePauseAndRestartsAfterTheSwap() {
        var limits = StreamLimits()
        limits.maxQueuedBytes = .max
        let session = StreamSession(transport: IdleTransport(), options: StartOptions(), limits: limits)
        let router = NotesFrameRouter()
        let frame = Data(count: 1600)
        #expect(!router.route(frame, level: Level(peak: 1, rms: 0.3)))   // no target yet: dropped, no time
        #expect(router.seconds == 0)
        _ = router.swap(to: session)
        var cuts: [Int] = []
        for i in 0..<500 {
            let level = i < 400 ? Level(peak: 1, rms: 0.3) : Level(peak: 0.01, rms: 0.001)
            if router.route(frame, level: level) { cuts.append(i) }
        }
        #expect(cuts == [411])                     // 20 s of speech, then 0.6 s of quiet
        let (old, offset) = router.swap(to: session)
        #expect(old != nil && offset == 25)
    }
}
