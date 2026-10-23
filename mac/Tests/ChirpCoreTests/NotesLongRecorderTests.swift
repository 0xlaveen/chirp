import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Long dictation through the recorder: clean-up context on `stop`, and whole-document Organize in steps.
@MainActor
@Suite(.serialized) struct NotesLongRecorderTests {
    private let frame = Data(count: 1600)
    private let speech = Level(peak: 0.5, rms: 0.2)
    private static let health = Health(correction: "available", notesStructure: true, notesCorrection: true,
                                       notesReorganize: true, notesContext: true)

    private func eventually(_ what: String, within seconds: Double = 60, _ condition: () -> Bool) async {
        if !(await pollUntil(within: seconds, condition)) { Issue.record("timed out waiting for \(what)") }
    }

    private func recorder(port: UInt16 = 9, stub: PassStub, clock: ManualClock, health: Health = health,
                          profile: String = CorrectionProfile.liveNotesID) -> NotesRecorder {
        let config = ServerConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        return NotesRecorder(makeSession: { StreamSession(config: config, options: $0) },
                             structure: { try await stub.structure($0) }, reorganize: { try await stub.reorganize($0) },
                             now: { clock.now }, sleep: { await clock.sleep($0) },
                             options: StartOptions(client: "mac", correction: true, correctionProfile: profile, wordTimings: true),
                             structuring: true, autoReorganize: false, health: health)
    }

    private func stops(_ server: MockServer) -> [String] { server.received.filter { $0.contains(#""type":"stop""#) } }

    private func twoCuts(_ health: Health, profile: String = CorrectionProfile.liveNotesID) async throws -> [String] {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        server.numberedFinals = true
        let stub = PassStub(), clock = ManualClock()
        let r = recorder(port: port, stub: stub, clock: clock, health: health, profile: profile)
        r.start()
        await eventually("ready") { r.state == .recording }
        for _ in 0..<4 { r.handleFrame(frame, level: speech) }
        await r.cut()
        await eventually("first final") { r.document.segments.count == 1 }
        for _ in 0..<4 { r.handleFrame(frame, level: speech) }
        await r.cut()
        await eventually("second final") { r.document.segments.count == 2 }
        await r.stop()
        return stops(server)
    }

    @Test func theNextSegmentsStopCarriesThePreviousFinalAsContext() async throws {
        let sent = try await twoCuts(Self.health)
        #expect(sent.first == ClientMessage.stop)                          // the first segment follows nothing
        #expect(sent.dropFirst().first == ClientMessage.stop(context: "Segment 0."))
    }

    @Test func noContextWithoutTheHealthFlagOrTheNotesStyle() async throws {
        var old = Self.health
        old.notesContext = nil
        #expect(try await twoCuts(old).allSatisfy { $0 == ClientMessage.stop })
        #expect(try await twoCuts(Self.health, profile: CorrectionProfile.defaultID).allSatisfy { $0 == ClientMessage.stop })
    }

    // MARK: whole-document Organize

    /// About 20 000 characters: 40 sections of ten bullets, with "Budget" at sections 3 and 35.
    static let longNotes: String = (0..<40).map { k in
        "## " + (k == 3 || k == 35 ? "Budget" : "Topic \(k)") + "\n"
            + (0..<10).map { "- bullet \(k).\($0) with enough words to make a line of notes\n" }.joined()
    }.joined(separator: "\n")

    /// Tidies every group (bullet → point) and merges a repeated "Budget" heading.
    private func organizer() -> PassStub {
        let stub = PassStub()
        stub.reorganizeReply = { r in
            var md = r.notes.replacingOccurrences(of: "bullet", with: "point").trimmingCharacters(in: .whitespacesAndNewlines)
            if let second = md.range(of: "\n\n## Budget\n", options: .backwards), md.components(separatedBy: "## Budget").count > 2 {
                md.replaceSubrange(second, with: "\n")
            }
            return NotesReorganizeResponse(markdown: md, reorganized: true, changed: true)
        }
        return stub
    }

    private func typed(_ r: NotesRecorder) {
        r.userEdit(NSRange(location: 0, length: 0), Self.longNotes)
    }

    @Test func organizeWalksALongDocumentOldestFirstThenMergesARepeatedHeading() async {
        #expect(Self.longNotes.unicodeScalars.count > 20_000)
        let stub = organizer(), clock = ManualClock()
        let r = recorder(stub: stub, clock: clock)
        var events: [NotesPassEvent] = []
        r.onPassEvent = { events.append($0) }
        typed(r)
        let groups = r.document.organizeGroupCount()
        #expect(groups >= 6)
        r.reorganizeNow()
        #expect(r.reorganizeStatus == .organizing(step: 1, of: groups + 1))
        await eventually("organized") { !r.reorganizeStatus.isRunning }
        let requests = stub.reorganizes
        #expect(requests.count == groups + 1)
        let steps = requests.dropLast()
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.range.location < $1.range.location })
        #expect(requests.allSatisfy { $0.notes.unicodeScalars.count <= NotesDocument.maxReorganizeChars })
        // Each step sees the other groups' headings, never its own (only the repeated one is in both).
        #expect(steps.allSatisfy { s in !s.outline.contains { $0 != "Budget" && s.notes.contains("## \($0)\n") } })
        #expect(steps.allSatisfy { s in !s.outline.isEmpty })
        #expect(requests.last?.merged.count == 1 && requests.last?.notes.components(separatedBy: "## Budget").count == 3)
        #expect(!r.document.text.contains("bullet") && r.document.text.components(separatedBy: "## Budget").count == 2)
        #expect(r.document.text.contains("- point 35.9"))
        if case .applied = r.reorganizeStatus {} else { Issue.record("status \(r.reorganizeStatus)") }
        #expect(events == [.organize(steps: groups + 1, failed: 0, conflict: false)])
        let changes = r.takePendingChanges()
        #expect(!changes.isEmpty && Set(changes.map(\.run)).count == 1 && changes.allSatisfy { $0.run != nil })
    }

    @Test func anEditDuringAStepKeepsTheStepsDoneAndStopsTheRest() async {
        let stub = organizer(), clock = ManualClock()
        stub.holdReorganize = true
        let r = recorder(stub: stub, clock: clock)
        typed(r)
        let groups = r.document.organizeGroupCount()
        r.reorganizeNow()
        await eventually("step 1 sent") { stub.waiting == 1 }
        stub.release()
        stub.holdReorganize = true
        await eventually("step 2 sent") { stub.waiting == 1 && stub.reorganizes.count == 2 }
        #expect(r.reorganizeStatus == .organizing(step: 2, of: groups + 1))
        r.userEdit(NSRange(location: 0, length: 0), "x")
        stub.release()
        await eventually("finished") { !r.reorganizeStatus.isRunning }
        #expect(stub.reorganizes.count == 2)
        #expect(r.reorganizeStatus == .conflict)
        let text = r.document.text
        #expect(text.hasPrefix("x## Topic 0\n- point 0.0") && text.contains("bullet 39.9"))
    }

    @Test func aLongDocumentIsOrganizedWholeAtStop() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        let stub = organizer(), clock = ManualClock()
        let config = ServerConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let r = NotesRecorder(makeSession: { StreamSession(config: config, options: $0) },
                              structure: { try await stub.structure($0) }, reorganize: { try await stub.reorganize($0) },
                              now: { clock.now }, sleep: { await clock.sleep($0) },
                              options: StartOptions(client: "mac", correction: true), structuring: true, autoReorganize: true,
                              health: Self.health)
        typed(r)
        r.start()
        await eventually("ready") { r.state == .recording }
        for _ in 0..<4 { r.handleFrame(frame, level: speech) }
        await r.stop()
        #expect(r.state == .stopped)
        #expect(stub.reorganizes.count > 2 && stub.reorganizes.first?.range.location == 0)
        #expect(!r.document.text.contains("bullet"))
    }
}

@MainActor
@Suite struct NotesOrganizeUndoTests {
    @Test func aWholeOrganizeRunIsOneUndoStep() {
        let h = NotesEditorTests.Harness(typed: NotesLongRecorderTests.longNotes)
        let before = h.text
        var d = h.model.document
        var cursor = 0
        for _ in 0..<3 {
            let request = d.organizeStep(from: cursor, final: false)!
            let md = request.notes.replacingOccurrences(of: "bullet", with: "point")
            var change = d.applyReorganize(NotesReorganizeResponse(markdown: md, reorganized: true, changed: true), for: request)!
            change.run = 7
            cursor = request.range.location + change.replacement.utf16.count
            h.model.document = d
            h.model.enqueue([change])
        }
        let after = h.text
        #expect(after == h.model.document.text && after != before)
        #expect(h.editor.undo.undoActionName == NotesEditorCoordinator.reorganizeAction)
        h.editor.undo.undo()
        #expect(h.text == before && h.model.document.text == before)
        h.editor.undo.redo()
        #expect(h.text == after && h.model.document.text == after)
    }
}
