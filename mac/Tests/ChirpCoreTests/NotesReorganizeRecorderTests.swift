import Foundation
import Testing
@testable import ChirpCore

/// Both notes backends behind one lock: records each call, can hold either kind until released, and counts how many
/// passes of any kind run at once.
final class PassStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _structures: [NotesStructureRequest] = []
    private var _reorganizes: [NotesReorganizeRequest] = []
    private var running = 0
    private var _maxRunning = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    var holdStructure = false
    var holdReorganize = false
    var structureReply: @Sendable (NotesStructureRequest) throws -> NotesStructureResponse = { r in
        NotesStructureResponse(markdown: "## Heard\n- \(r.transcript.split(separator: "\n").count) segments", structured: true)
    }
    var reorganizeReply: @Sendable (NotesReorganizeRequest) throws -> NotesReorganizeResponse = { r in
        NotesReorganizeResponse(markdown: r.notes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n- tidied", reorganized: true)
    }

    var structures: [NotesStructureRequest] { lock.withLock { _structures } }
    var reorganizes: [NotesReorganizeRequest] { lock.withLock { _reorganizes } }
    var maxRunning: Int { lock.withLock { _maxRunning } }
    var waiting: Int { lock.withLock { held.count } }

    private func enter(hold: Bool) async {
        let shouldHold = lock.withLock { () -> Bool in
            running += 1
            _maxRunning = max(_maxRunning, running)
            return hold
        }
        if shouldHold { await withCheckedContinuation { c in lock.withLock { held.append(c) } } }
    }

    func structure(_ r: NotesStructureRequest) async throws -> NotesStructureResponse {
        lock.withLock { _structures.append(r) }
        await enter(hold: holdStructure)
        defer { lock.withLock { running -= 1 } }
        return try structureReply(r)
    }

    func reorganize(_ r: NotesReorganizeRequest) async throws -> NotesReorganizeResponse {
        lock.withLock { _reorganizes.append(r) }
        await enter(hold: holdReorganize)
        defer { lock.withLock { running -= 1 } }
        return try reorganizeReply(r)
    }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holdStructure = false
            holdReorganize = false
            defer { held.removeAll() }
            return held
        }
        for c in waiting { c.resume() }
    }
}

@MainActor
@Suite(.serialized) struct NotesReorganizeRecorderTests {
    private let frame = Data(count: 1600)
    private let speech = Level(peak: 0.5, rms: 0.2)
    private static let health = Health(correction: "available", notesStructure: true, notesReorganize: true)

    private func make(_ port: UInt16, _ stub: PassStub, _ clock: ManualClock, health: Health? = health,
                      auto: Bool = true) -> NotesRecorder {
        let config = ServerConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        return NotesRecorder(makeSession: { StreamSession(config: config, options: $0) },
                             structure: { try await stub.structure($0) }, reorganize: { try await stub.reorganize($0) },
                             now: { clock.now }, sleep: { await clock.sleep($0) },
                             options: StartOptions(client: "mac", correction: true), structuring: true, autoReorganize: auto,
                             health: health)
    }

    private func eventually(_ what: String, within seconds: Double = 60, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Lets timers and tasks that were just started reach their `sleep`, so a clock advance finds them.
    private func settle() async { try? await Task.sleep(for: .milliseconds(80)) }

    private func recording(_ stub: PassStub, _ clock: ManualClock, health: Health? = health, auto: Bool = true)
        async throws -> (NotesRecorder, MockServer) {
        let server = try MockServer()
        let port = try await server.start()
        server.numberedFinals = true
        let r = make(port, stub, clock, health: health, auto: auto)
        r.start()
        await eventually("ready") { r.state == .recording }
        return (r, server)
    }

    /// Typed notes: whole sections of about `chars` characters at the end of the document.
    private func type(_ r: NotesRecorder, chars: Int, title: String = "Typed") {
        let text = "## \(title)\n" + String(repeating: "- a typed point\n", count: max(1, chars / 16))
        r.userEdit(NSRange(location: r.document.text.utf16.count, length: 0), text)
    }

    /// The stub's reorganize landed (the scope keeps its trailing newline).
    private func tidied(_ r: NotesRecorder) -> Bool {
        r.document.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("- tidied")
    }

    private func segment(_ r: NotesRecorder) async {
        for _ in 0..<2 { r.handleFrame(frame, level: speech) }
        await r.cut()
    }

    @Test func autoWaitsForCharsAndIntervalAndTypingIdle() async throws {
        let stub = PassStub(), clock = ManualClock()
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        type(r, chars: 600)                                   // under reorganizeEveryChars
        await settle()
        clock.advance(NotesRecorder.reorganizeMinInterval + 1)
        await settle()
        #expect(stub.reorganizes.isEmpty)
        type(r, chars: 700, title: "More")                    // enough now, but typing just happened
        await settle()
        clock.advance(NotesRecorder.typingIdle - 1)
        await settle()
        #expect(stub.reorganizes.isEmpty)
        type(r, chars: 16, title: "Last")                     // still typing: the idle clock restarts
        await settle()
        clock.advance(NotesRecorder.typingIdle - 1)
        await settle()
        #expect(stub.reorganizes.isEmpty)
        clock.advance(1)
        await eventually("auto reorganize") { stub.reorganizes.count == 1 }
        await eventually("applied") { if case .applied = r.reorganizeStatus { true } else { false } }
        #expect(tidied(r) && r.document.charsSinceReorganize == 0)
        #expect(r.takePendingChanges().last?.kind == .reorganize)
        // The interval since the last one now holds the next one back.
        type(r, chars: 1300, title: "Again")
        await settle()
        clock.advance(NotesRecorder.typingIdle + 1)
        await settle()
        #expect(stub.reorganizes.count == 1)
        clock.advance(NotesRecorder.reorganizeMinInterval)
        await eventually("second reorganize") { stub.reorganizes.count == 2 }
        await r.stop()
    }

    @Test func appendWinsAndPassesNeverOverlap() async throws {
        let stub = PassStub(), clock = ManualClock()
        stub.holdStructure = true
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        await segment(r)
        await eventually("append running") { stub.waiting == 1 }
        type(r, chars: 1300)
        await settle()
        clock.advance(NotesRecorder.reorganizeMinInterval + NotesRecorder.typingIdle)
        await settle()
        // Reorganize is due, but the slot is taken.
        #expect(stub.reorganizes.isEmpty)
        await segment(r)                                      // and another append becomes due
        await eventually("segment 1") { r.document.segments.count == 2 }
        stub.release()
        await eventually("first append done") { !r.passInFlight && stub.structures.count == 1 }
        await settle()
        // The append waits out minInterval and still goes first.
        #expect(stub.reorganizes.isEmpty)
        clock.advance(NotesRecorder.minInterval)
        await eventually("second append") { stub.structures.count == 2 }
        await eventually("then the reorganize") { stub.reorganizes.count == 1 }
        #expect(stub.maxRunning == 1)
        await r.stop()
        #expect(stub.maxRunning == 1)
    }

    @Test func anEditDuringAManualReorganizeIsAConflict() async throws {
        let stub = PassStub(), clock = ManualClock()
        stub.holdReorganize = true
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        type(r, chars: 200)
        r.reorganizeNow()
        await eventually("reorganize running") { stub.waiting == 1 }
        #expect(r.reorganizeStatus == .running)
        r.userEdit(NSRange(location: 0, length: 0), "x")
        let typed = r.document.text
        stub.release()
        await eventually("finished") { !r.passInFlight }
        #expect(r.reorganizeStatus == .conflict && r.document.text == typed)
        #expect(!r.takePendingChanges().contains { $0.kind == .reorganize })
        await r.stop()
    }

    @Test func anEditDuringAnAutoReorganizeRetriesSilently() async throws {
        let stub = PassStub(), clock = ManualClock()
        stub.holdReorganize = true
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        type(r, chars: 1300)
        await settle()
        clock.advance(NotesRecorder.reorganizeMinInterval)
        await eventually("auto running") { stub.waiting == 1 }
        r.userEdit(NSRange(location: 0, length: 0), "x")
        stub.holdReorganize = false
        stub.release()
        await eventually("discarded") { !r.passInFlight }
        #expect(r.reorganizeStatus == .idle && !tidied(r))
        await settle()
        clock.advance(NotesRecorder.reorganizeRetryAfter - 1)
        await settle()
        #expect(stub.reorganizes.count == 1)
        clock.advance(1)
        await eventually("retry") { stub.reorganizes.count == 2 }
        await eventually("applied") { tidied(r) }
        await r.stop()
    }

    @Test func manualSkipsThresholdsButWaitsForAPass() async throws {
        let stub = PassStub(), clock = ManualClock()
        stub.holdStructure = true
        let (r, server) = try await recording(stub, clock, auto: false)
        defer { server.stop() }
        type(r, chars: 200)                                    // far under the threshold, no time passed
        await segment(r)
        await eventually("append running") { stub.waiting == 1 }
        r.reorganizeNow()
        await settle()
        #expect(stub.reorganizes.isEmpty)
        stub.release()
        await eventually("manual reorganize") { stub.reorganizes.count == 1 }
        #expect(stub.reorganizes[0].final == false && stub.maxRunning == 1)
        await r.stop()
    }

    @Test func theAutoToggleStopsAutomaticPassesOnly() async throws {
        let stub = PassStub(), clock = ManualClock()
        let (r, server) = try await recording(stub, clock, auto: false)
        defer { server.stop() }
        type(r, chars: 1300)
        await settle()
        clock.advance(NotesRecorder.reorganizeMinInterval * 2)
        await settle()
        #expect(stub.reorganizes.isEmpty)
        r.reorganizeNow()
        await eventually("manual still works") { stub.reorganizes.count == 1 }
        r.setAutoReorganize(true)
        await r.stop()                                         // Stop's final append changed the notes: one final pass
        #expect(stub.reorganizes.map(\.final) == [false, true])
    }

    @Test func stopIsFinalAppendThenSettleThenOneFinalReorganize() async throws {
        let stub = PassStub(), clock = ManualClock()
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        type(r, chars: 200)
        for _ in 0..<2 { r.handleFrame(frame, level: speech) }
        await r.stop()
        #expect(stub.structures.map(\.final) == [true])
        #expect(stub.reorganizes.map(\.final) == [true])
        #expect(r.state == .stopped && tidied(r) && r.document.tail.isEmpty)
        // The final reorganize saw the appended notes.
        #expect(stub.reorganizes[0].notes.contains("## Heard"))
    }

    @Test func anEditDuringTheStopReorganizeStillStops() async throws {
        let stub = PassStub(), clock = ManualClock()
        stub.holdReorganize = true
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        type(r, chars: 200)
        let stopping = Task { await r.stop() }
        await eventually("final reorganize running") { stub.waiting == 1 }
        #expect(r.state == .stopping && r.reorganizeStatus == .running)
        r.userEdit(NSRange(location: 0, length: 0), "x")
        stub.release()
        await stopping.value
        #expect(r.state == .stopped && r.document.text.hasPrefix("x## Typed") && !tidied(r))
        #expect(stub.reorganizes.count == 1)
    }

    @Test func a404HidesOnlyReorganize() async throws {
        let stub = PassStub(), clock = ManualClock()
        stub.reorganizeReply = { _ in throw NotesStructureError.unsupported(404) }
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        type(r, chars: 200)
        r.reorganizeNow()
        await eventually("404") { r.reorganizeStatus == .unavailable(.unsupported) }
        #expect(r.structuring == .idle)
        await segment(r)
        await eventually("appends still run") { stub.structures.count == 1 }
        // Health still advertising it does not bring it back this session.
        r.configureStructuring(enabled: true, health: Self.health)
        #expect(r.reorganizeStatus == .unavailable(.unsupported))
        await r.stop()
    }

    @Test func a409TurnsOffBoth() async throws {
        let stub = PassStub(), clock = ManualClock()
        stub.reorganizeReply = { _ in throw NotesStructureError.off }
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        type(r, chars: 200)
        r.reorganizeNow()
        await eventually("409") { r.structuring == .off(.correctionOff) }
        #expect(r.reorganizeStatus == .unavailable(.correctionOff))
        await r.stop()
    }

    @Test func anOldServerHasNoReorganize() {
        let r = make(1, PassStub(), ManualClock(), health: Health(correction: "available", notesStructure: true))
        #expect(r.structuring == .idle && r.reorganizeStatus == .unavailable(.unsupported))
        r.reorganizeNow()
        #expect(!r.passInFlight)
    }

    @Test func anAppendIsHeldWhileTypingInTheTail() async throws {
        let stub = PassStub(), clock = ManualClock()
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        r.setEditorFocus(inTail: true, composing: false)
        r.userEdit(NSRange(location: 0, length: 0), "typing at the end")
        await segment(r)
        await eventually("first pass") { stub.structures.count == 1 && !r.passInFlight }
        #expect(r.isHolding && r.document.text == "typing at the end")
        // Keep typing (at the end: the tail is still empty) so the hold outlasts minInterval; a newer pass replaces
        // the held answer.
        await settle()
        clock.advance(NotesRecorder.holdMax - 2)
        r.userEdit(NSRange(location: 17, length: 0), "!")
        await settle()
        clock.advance(NotesRecorder.minInterval - NotesRecorder.holdMax + 2)
        await settle()
        #expect(r.isHolding && r.document.text == "typing at the end!" && stub.structures.count == 1)   // nothing new to send
        await segment(r)
        await eventually("second pass") { stub.structures.count == 2 && !r.passInFlight }
        #expect(r.isHolding && r.document.text == "typing at the end!")
        // Leaving the tail applies the newest.
        r.setEditorFocus(inTail: false, composing: false)
        #expect(!r.isHolding && r.document.text == "typing at the end!\n\n## Heard\n- 2 segments")
        #expect(r.takePendingChanges().map(\.kind) == [.append])
        await r.stop()
    }

    @Test func aHeldAppendLandsAfterHoldMaxWithoutKeystrokes() async throws {
        let stub = PassStub(), clock = ManualClock()
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        r.setEditorFocus(inTail: true, composing: false)
        r.userEdit(NSRange(location: 0, length: 0), "x")
        await segment(r)
        await eventually("held") { r.isHolding }
        await settle()
        clock.advance(NotesRecorder.holdMax - 1)
        await settle()
        #expect(r.isHolding)
        clock.advance(1)
        await eventually("released") { !r.isHolding }
        #expect(r.document.text == "x\n\n## Heard\n- 1 segments")
        await r.stop()
    }

    @Test func composingHoldsAndAClaimDropsTheHeldAnswer() async throws {
        let stub = PassStub(), clock = ManualClock()
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        await segment(r)
        await eventually("first append") { r.document.text == "## Heard\n- 1 segments" }
        r.setEditorFocus(inTail: true, composing: true)
        await settle()
        clock.advance(NotesRecorder.minInterval)
        await segment(r)
        await eventually("held while composing") { r.isHolding }
        // The composition commits inside the tail: a claim, so the held answer is for a stale tail and goes away.
        r.userEdit(NSRange(location: 3, length: 0), "日本")
        #expect(!r.isHolding && r.document.tail.isEmpty)
        r.setEditorFocus(inTail: true, composing: false)
        #expect(r.document.text == "## 日本Heard\n- 1 segments")
        // The segments after the claim go out again.
        await settle()
        clock.advance(NotesRecorder.minInterval)
        await r.stop()
        #expect(stub.structures.last?.transcript.hasPrefix("Segment 1.") == true, "\(stub.structures.map(\.transcript))")
    }
}
