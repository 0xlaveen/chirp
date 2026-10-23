import Foundation
import Testing
@testable import ChirpCore

/// Pause and Resume on the recorder (#65), against the mock server and a fake clock.
@MainActor
@Suite(.serialized) struct NotesPauseTests {
    private let frame = Data(count: 1600)
    private let speech = Level(peak: 0.5, rms: 0.2)

    private func make(port: UInt16, stub: StructureStub, clock: ManualClock) -> NotesRecorder {
        let config = ServerConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        return NotesRecorder(makeSession: { StreamSession(config: config, options: $0) },
                             structure: { try await stub.call($0) },
                             now: { clock.now }, sleep: { await clock.sleep($0) },
                             options: StartOptions(client: "mac", correction: true), structuring: true,
                             health: Health(correction: "available", notesStructure: true))
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(60)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func send(_ r: NotesRecorder, frames n: Int) {
        for _ in 0..<n { r.handleFrame(frame, level: speech) }
    }

    private func recording() async throws -> (NotesRecorder, MockServer, StructureStub, ManualClock) {
        let server = try MockServer()
        let port = try await server.start()
        server.numberedFinals = true
        let stub = StructureStub(), clock = ManualClock()
        let r = make(port: port, stub: stub, clock: clock)
        r.start()
        await eventually("ready") { r.state == .recording }
        return (r, server, stub, clock)
    }

    @Test func pauseFinalizesTheSegmentWithoutAFinalPassAndStopsTheClock() async throws {
        let (r, server, stub, _) = try await recording()
        defer { server.stop() }
        send(r, frames: 5)
        let before = r.elapsed
        await r.pause()
        #expect(r.state == .paused && r.state.isActive && !r.state.isCapturing)
        await eventually("segment committed") { r.document.segments.count == 1 }
        send(r, frames: 5)   // capture is closed: nothing is routed
        #expect(r.elapsed == before)
        #expect(server.bytesBySocket == [0: 5 * 1600])
        #expect(!stub.requests.contains { $0.final })
        #expect(r.document.segments.count == 1)
    }

    @Test func pauseKeepsTheTailOpenUntilStop() async throws {
        let (r, server, stub, _) = try await recording()
        defer { server.stop() }
        send(r, frames: 5)
        await r.pause()
        await eventually("segment committed") { r.document.segments.count == 1 }
        await eventually("append pass") { !stub.requests.isEmpty }
        #expect(stub.requests.allSatisfy { !$0.final })
        #expect(r.document.tail.isEmpty == false || r.document.text.isEmpty == false)
        // Frozen text would have no tail window left to extend.
        await r.resume()
        send(r, frames: 3)
        await r.cut()
        await eventually("second segment") { r.document.segments.count == 2 }
        await r.stop()
        #expect(stub.requests.contains { $0.final })
    }

    @Test func resumeContinuesOnAFreshSocketWithoutANewStartStamp() async throws {
        let (r, server, _, _) = try await recording()
        defer { server.stop() }
        let stamp = r.document.startedAt
        send(r, frames: 4)
        await r.pause(reason: "Paused while the Mac slept")
        #expect(r.pauseReason == "Paused while the Mac slept")
        await r.resume()
        #expect(r.state == .recording && r.pauseReason == nil)
        send(r, frames: 6)
        #expect(r.document.startedAt == stamp)
        #expect(r.elapsed == Double(10 * 1600) / (PCMConverter.sampleRate * 2))
        await r.stop()
        #expect(server.bytesBySocket == [0: 4 * 1600, 1: 6 * 1600])
        #expect(r.state == .stopped)
        #expect(r.document.segments.count == 2)
    }

    @Test func stopFromPausedFinalizesAsToday() async throws {
        let (r, server, stub, _) = try await recording()
        defer { server.stop() }
        send(r, frames: 5)
        await r.pause()
        await r.stop()
        #expect(r.state == .stopped)
        #expect(r.document.segments.count == 1)
        #expect(stub.requests.contains { $0.final })
        #expect(r.document.livePartial.isEmpty)
    }

    @Test func pauseAndResumeAreIgnoredInOtherStates() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        let r = make(port: port, stub: StructureStub(), clock: ManualClock())
        await r.pause()
        await r.resume()
        #expect(r.state == .idle)
        r.start()
        await r.pause()   // still connecting: nothing to cut yet
        #expect(r.state != .paused)
        await eventually("ready") { r.state == .recording }
        await r.resume()
        #expect(r.state == .recording)
        await r.stop()
    }

    @Test func resetIsRefusedWhilePausedAndNewIsDisabled() async throws {
        let (r, server, _, _) = try await recording()
        defer { server.stop() }
        send(r, frames: 5)
        await r.pause()
        r.reset()
        #expect(r.state == .paused)
        await r.stop()
    }
}
