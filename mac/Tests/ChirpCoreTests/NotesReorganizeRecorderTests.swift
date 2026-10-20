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

/// Counts calls across `@Sendable` closures.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
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

    /// Two sections of about 700 chars each: over `reorganizeEveryChars` in all, and each within the recording scope.
    private func typeTwoSections(_ r: NotesRecorder, _ tag: String = "") {
        type(r, chars: 700, title: "First\(tag)")
        type(r, chars: 700, title: "Second\(tag)")
    }

    @Test func autoRunsOnlyRightAfterACommitOnTheRecordingScope() async throws {
        let stub = PassStub(), clock = ManualClock()
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        typeTwoSections(r)
        await settle()
        clock.advance(NotesRecorder.reorganizeMinInterval + 1)
        await settle()
        // Everything is due, but no segment was committed: no timer starts a reorganize mid-segment.
        #expect(stub.reorganizes.isEmpty)
        await segment(r)
        await eventually("append, then auto reorganize") { stub.reorganizes.count == 1 }
        #expect(stub.structures.count == 1 && stub.maxRunning == 1)
        // While recording only the trailing whole sections within recordingReorganizeChars go.
        let sent = stub.reorganizes[0]
        #expect(sent.notes.unicodeScalars.count <= NotesDocument.recordingReorganizeChars && sent.notes.contains("## Heard"))
        #expect(!sent.notes.contains("## First") && sent.outline.contains("First"))
        await eventually("applied") { if case .applied = r.reorganizeStatus { true } else { false } }
        #expect(tidied(r) && r.document.charsSinceReorganize == 0)
        #expect(r.takePendingChanges().last?.kind == .reorganize)
        // Enough new text, but the interval since the last one holds the next one back…
        typeTwoSections(r, "2")
        await settle()
        clock.advance(NotesRecorder.minInterval)
        await segment(r)
        await eventually("second append") { stub.structures.count == 2 && !r.passInFlight }
        #expect(stub.reorganizes.count == 1)
        // …and so does recent typing.
        clock.advance(NotesRecorder.reorganizeMinInterval - 5)
        r.userEdit(NSRange(location: 0, length: 0), "x")
        await segment(r)
        await eventually("third append") { stub.structures.count == 3 && !r.passInFlight }
        #expect(stub.reorganizes.count == 1)
        clock.advance(NotesRecorder.typingIdle)
        await segment(r)
        await eventually("second reorganize") { stub.reorganizes.count == 2 }
        await r.stop()
    }

    @Test func appendGoesFirstAndPassesNeverOverlap() async throws {
        let stub = PassStub(), clock = ManualClock()
        stub.holdStructure = true
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        typeTwoSections(r)
        await settle()
        clock.advance(NotesRecorder.reorganizeMinInterval + NotesRecorder.typingIdle)
        await segment(r)
        await eventually("append running") { stub.waiting == 1 }
        await settle()
        #expect(stub.reorganizes.isEmpty)                      // due, but the slot is the append's
        stub.release()
        await eventually("then the reorganize") { stub.reorganizes.count == 1 }
        #expect(stub.structures.count == 1 && stub.maxRunning == 1)
        await r.stop()
        #expect(stub.maxRunning == 1)
    }

    @Test func aPreemptedReorganizeIsNotAFailure() async throws {
        let stub = PassStub(), clock = ManualClock()
        let calls = Counter()
        stub.reorganizeReply = { r in
            if calls.next() == 0 { return NotesReorganizeResponse(markdown: nil, reorganized: false, changed: false, error: "preempted") }
            return NotesReorganizeResponse(markdown: r.notes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n- tidied", reorganized: true)
        }
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        typeTwoSections(r)
        await settle()
        clock.advance(NotesRecorder.reorganizeMinInterval + 1)
        await segment(r)
        await eventually("preempted") { stub.reorganizes.count == 1 && !r.passInFlight }
        #expect(r.reorganizeStatus == .idle)                   // no "Couldn't reorganize" note
        // No backoff: the next commit (once its append has run) tries again.
        clock.advance(NotesRecorder.minInterval)
        await segment(r)
        await eventually("retried after the next commit") { stub.reorganizes.count == 2 }
        await eventually("applied") { tidied(r) }
        await r.stop()
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
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        typeTwoSections(r)
        await settle()
        clock.advance(NotesRecorder.reorganizeMinInterval)
        stub.holdReorganize = true
        await segment(r)
        await eventually("auto running") { stub.waiting == 1 }
        r.userEdit(NSRange(location: 0, length: 0), "x")
        stub.release()
        await eventually("discarded") { !r.passInFlight }
        #expect(r.reorganizeStatus == .idle && !tidied(r))
        clock.advance(NotesRecorder.reorganizeRetryAfter - 1)
        await segment(r)
        await eventually("append") { stub.structures.count == 2 && !r.passInFlight }
        #expect(stub.reorganizes.count == 1)
        clock.advance(NotesRecorder.minInterval)
        await segment(r)
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
        typeTwoSections(r)
        await settle()
        clock.advance(NotesRecorder.reorganizeMinInterval * 2)
        await segment(r)
        await eventually("append") { stub.structures.count == 1 && !r.passInFlight }
        #expect(stub.reorganizes.isEmpty)
        r.reorganizeNow()
        await eventually("manual still works") { stub.reorganizes.count == 1 }
        // A manual one sends the full scope, not the recording one.
        #expect(stub.reorganizes[0].notes.unicodeScalars.count > NotesDocument.recordingReorganizeChars)
        r.setAutoReorganize(true)
        await r.stop()                                         // Stop's final append changed the notes: one final pass
        #expect(stub.reorganizes.map(\.final) == [false, true])
    }

    @Test func stopSkipsItsReorganizeRightAfterOneOnTheSameText() async throws {
        for (wait, expected) in [(0.0, 1), (NotesRecorder.stopReorganizeSkip + 1, 2)] {
            let stub = PassStub(), clock = ManualClock()
            // The same Markdown every time, so Stop's own append changes nothing; a reorganize that fails.
            stub.structureReply = { _ in NotesStructureResponse(markdown: "## Heard\n- the same", structured: true) }
            stub.reorganizeReply = { _ in .failed("rejected") }
            let (r, server) = try await recording(stub, clock)
            defer { server.stop() }
            type(r, chars: 200)
            await segment(r)
            await eventually("append") { stub.structures.count == 1 && !r.passInFlight }
            r.reorganizeNow()
            await eventually("reorganize") { stub.reorganizes.count == 1 && !r.passInFlight }
            clock.advance(wait)
            await r.stop()
            #expect(stub.reorganizes.count == expected, "after \(wait) s")
            #expect(r.state == .stopped)
        }
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
        #expect(r.state == .stopping && r.reorganizeStatus == .running && r.stoppingElapsed != nil)
        r.userEdit(NSRange(location: 0, length: 0), "x")
        stub.release()
        await stopping.value
        #expect(r.state == .stopped && r.document.text.hasPrefix("x## Typed") && !tidied(r) && r.stoppingElapsed == nil)
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

    @Test func aReorganizeThatLandsDropsAHeldAppend() async throws {
        let stub = PassStub(), clock = ManualClock()
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        type(r, chars: 200)
        r.setEditorFocus(inTail: true, composing: false)
        r.userEdit(NSRange(location: r.document.text.utf16.count, length: 0), "!")
        await segment(r)
        await eventually("held") { r.isHolding }
        r.reorganizeNow()
        await eventually("applied") { tidied(r) }
        #expect(!r.isHolding)
        await r.stop()
    }

    @Test func aReorganizeIsDiscardedWhileComposing() async throws {
        let stub = PassStub(), clock = ManualClock()
        stub.holdReorganize = true
        let (r, server) = try await recording(stub, clock)
        defer { server.stop() }
        type(r, chars: 200)
        r.reorganizeNow()
        await eventually("running") { stub.waiting == 1 }
        r.setEditorFocus(inTail: false, composing: true)
        let before = r.document.text
        stub.release()
        await eventually("finished") { !r.passInFlight }
        #expect(r.document.text == before && r.reorganizeStatus == .conflict)
        r.setEditorFocus(inTail: false, composing: false)
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
