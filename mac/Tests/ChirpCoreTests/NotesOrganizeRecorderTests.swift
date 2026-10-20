import Foundation
import Testing
@testable import ChirpCore

/// Split-on-reject for appends, and Organize (orchestrator follow-up on #17).
@MainActor
@Suite(.serialized) struct NotesOrganizeRecorderTests {
    private let frame = Data(count: 1600)
    private let speech = Level(peak: 0.5, rms: 0.2)
    private static let health = Health(correction: "available", notesStructure: true, notesReorganize: true)
    /// Twelve sentences of 41 characters each: halves split exactly between `alpha` and `gamma`.
    private static let alpha = String(repeating: "Alpha item number one is on track today. ", count: 12)
    private static let gamma = String(repeating: "Gamma item number two is on track today. ", count: 12)
    private static let window = (alpha + gamma).trimmingCharacters(in: .whitespaces)

    /// The server: a whole window over 700 chars is rejected; so is anything about gamma when `poison` is set.
    private func stub(poison: Bool) -> PassStub {
        let stub = PassStub()
        let flag = Flag(poison)
        stub.structureReply = { r in
            if r.transcript.count > 700 || (flag.value && r.transcript.contains("Gamma")) {
                return NotesStructureResponse(markdown: nil, structured: false, error: "rejected", reason: "novel_name")
            }
            return NotesStructureResponse(markdown: "- part of \(r.transcript.count)", structured: true)
        }
        stub.poison = flag
        return stub
    }

    private func recording(_ stub: PassStub, _ clock: ManualClock, final text: String = window)
        async throws -> (NotesRecorder, MockServer, [NotesPassEvent]) {
        let server = try MockServer()
        let port = try await server.start()
        server.script(0, .init(finalText: text))
        let config = ServerConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let r = NotesRecorder(makeSession: { StreamSession(config: config, options: $0) },
                              structure: { try await stub.structure($0) }, reorganize: { try await stub.reorganize($0) },
                              now: { clock.now }, sleep: { await clock.sleep($0) },
                              options: StartOptions(client: "mac", correction: true), structuring: true, autoReorganize: false,
                              health: Self.health)
        r.start()
        await eventually("ready") { r.state == .recording }
        return (r, server, [])
    }

    private func eventually(_ what: String, within seconds: Double = 30, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func segment(_ r: NotesRecorder) async {
        for _ in 0..<2 { r.handleFrame(frame, level: speech) }
        await r.cut()
    }

    @Test func aRejectedWindowIsStructuredInHalvesAndAppendedInOrder() async throws {
        let stub = stub(poison: false), clock = ManualClock()
        let (r, server, _) = try await recording(stub, clock)
        defer { server.stop() }
        var events: [NotesPassEvent] = []
        r.onPassEvent = { events.append($0) }
        await segment(r)
        await eventually("split applied") { r.document.text.contains("- part of") && !r.passInFlight }
        #expect(stub.structures.map(\.transcript.count) == [Self.window.count, 491, 491])
        #expect(r.document.text == "- part of 491\n\n- part of 491" && r.document.tail.isEmpty)
        #expect(r.structuring == .idle && events == [.split(windowChars: Self.window.count, depth: 1, parts: 2, fallbacks: 0)])
        await r.stop()
    }

    @Test func onlyThePartThatKeepsFailingFallsBack() async throws {
        let stub = stub(poison: true), clock = ManualClock()
        let (r, server, _) = try await recording(stub, clock)
        defer { server.stop() }
        var events: [NotesPassEvent] = []
        r.onPassEvent = { events.append($0) }
        await segment(r)
        await eventually("split applied") { r.document.text.contains(NotesDocument.fallbackHeader) && !r.passInFlight }
        // The gamma half is under twice the minimum, so it is not split again: it alone stays raw.
        #expect(r.document.text == "- part of 491\n\n" + NotesDocument.fallbackBlock(Self.gamma.trimmingCharacters(in: .whitespaces)))
        #expect(r.structuring == .failed("rejected: novel_name"))
        #expect(events == [.split(windowChars: Self.window.count, depth: 1, parts: 2, fallbacks: 1)])
        await r.stop()
    }

    @Test func aTransientFailureOfAPartKeepsTheNormalRetry() async throws {
        let stub = PassStub(), clock = ManualClock()
        let calls = Counter()
        stub.structureReply = { _ in
            calls.next() == 0 ? NotesStructureResponse(markdown: nil, structured: false, error: "rejected") : .failed("timeout")
        }
        let (r, server, _) = try await recording(stub, clock)
        defer { server.stop() }
        await segment(r)
        await eventually("failed") { r.structuring == .failed("timeout") && !r.passInFlight }
        #expect(r.document.text.isEmpty && r.document.consecutiveFailures == 1 && r.document.untouchedFallbacks.isEmpty)
        await r.stop()
    }

    /// Records with the gamma half poisoned (it lands as a fallback block), then stops.
    private func stoppedWithAFallback(_ stub: PassStub, _ clock: ManualClock) async throws -> (NotesRecorder, MockServer) {
        let (r, server, _) = try await recording(stub, clock)
        await segment(r)
        await eventually("fallback") { r.document.text.contains(NotesDocument.fallbackHeader) && !r.passInFlight }
        await r.stop()
        #expect(r.document.untouchedFallbacks.count == 1)
        return (r, server)
    }

    @Test func organizeReStructuresAFallbackBlockInPlaceThenReorganizes() async throws {
        let stub = stub(poison: true), clock = ManualClock()
        let (r, server) = try await stoppedWithAFallback(stub, clock)
        defer { server.stop() }
        r.userEdit(NSRange(location: 0, length: 0), "## Plan\n- a typed point about the launch and the budget review\n\n")
        _ = r.takePendingChanges()
        stub.poison?.value = false                             // the server would take it now
        stub.holdStructure = true
        r.reorganizeNow()
        await eventually("organizing") { stub.waiting == 1 }
        #expect(r.reorganizeStatus == .organizing(step: 1, of: 2))
        stub.release()
        await eventually("organized") { !r.passInFlight }
        #expect(!r.document.text.contains(NotesDocument.fallbackHeader) && r.document.untouchedFallbacks.isEmpty)
        #expect(r.document.text.contains("- part of 491\n\n- part of 491"))
        #expect(stub.reorganizes.count == 1)
        if case .applied = r.reorganizeStatus {} else { Issue.record("expected applied, got \(r.reorganizeStatus)") }
        #expect(r.takePendingChanges().map(\.kind) == [.organize, .reorganize])
    }

    @Test func organizeLeavesAFallbackTheUserEdited() async throws {
        let stub = stub(poison: true), clock = ManualClock()
        let (r, server) = try await stoppedWithAFallback(stub, clock)
        defer { server.stop() }
        let at = (r.document.text as NSString).range(of: "Gamma").location
        r.userEdit(NSRange(location: at, length: 5), "GAMMA")
        stub.poison?.value = false
        let calls = stub.structures.count
        r.reorganizeNow()
        await eventually("reorganized") { stub.reorganizes.count == 1 && !r.passInFlight }
        // Only the reorganize ran: no structure call touched the edited block, and it is still there.
        #expect(stub.structures.count == calls)
        #expect(r.document.text.contains(NotesDocument.fallbackHeader + "\n\nGAMMA item"))
    }

    @Test func anEditWhileOrganizingDiscardsTheReplacement() async throws {
        let stub = stub(poison: true), clock = ManualClock()
        let (r, server) = try await stoppedWithAFallback(stub, clock)
        defer { server.stop() }
        stub.poison?.value = false
        stub.holdStructure = true
        r.reorganizeNow()
        await eventually("organizing") { stub.waiting == 1 }
        r.userEdit(NSRange(location: 0, length: 0), "x")
        let typed = r.document.text
        stub.release()
        await eventually("finished") { !r.passInFlight }
        #expect(r.reorganizeStatus == .conflict && r.document.text == typed)
        #expect(r.document.untouchedFallbacks.count == 1 && stub.reorganizes.isEmpty)
    }

    @Test func aBlockThatStillFailsIsKeptAndReported() async throws {
        let stub = stub(poison: true), clock = ManualClock()
        let (r, server) = try await stoppedWithAFallback(stub, clock)
        defer { server.stop() }
        r.reorganizeNow()
        await eventually("organized") { if case .organized = r.reorganizeStatus { true } else { false } }
        #expect(r.reorganizeStatus == .organized(failed: 1, reason: "rejected: novel_name"))
        #expect(r.document.untouchedFallbacks.count == 1)
    }
}

/// A Bool shared with a `@Sendable` reply closure.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
