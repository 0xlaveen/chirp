import Foundation
import Testing
@testable import ChirpCore

/// Review regressions for feat/notes-edit (issue #17): recorder.
@MainActor
@Suite(.serialized) struct NotesReviewRecorderRegressionTests {
    /// New (or closing with Discard) while a manual reorganize is in flight: the late result belongs to the discarded
    /// document and must never be applied to the new one. `reset()` neither cancels the pass nor bumps the epoch, so
    /// when the new document's `version` happens to equal the request's, `applyReorganize` replaces the request's
    /// (old) range in the new text: discarded notes come back and the user's new text is overwritten. With a new text
    /// shorter than that range the same path raises NSRangeException (crash).
    @Test func aReorganizeFromADiscardedDocumentNeverLandsInTheNewOne() async throws {
        let stub = PassStub(), clock = ManualClock()
        stub.holdReorganize = true
        let r = NotesRecorder(makeSession: { StreamSession(config: ServerConfig(baseURL: URL(string: "http://127.0.0.1:9")!), options: $0) },
                              structure: { try await stub.structure($0) }, reorganize: { try await stub.reorganize($0) },
                              now: { clock.now }, sleep: { await clock.sleep($0) },
                              options: StartOptions(client: "mac", correction: true), structuring: true,
                              health: Health(correction: "available", notesStructure: true, notesReorganize: true))
        let old = "## Secret\n" + String(repeating: "- discarded point\n", count: 8)
        r.userEdit(NSRange(location: 0, length: 0), old)                       // version 1
        r.reorganizeNow()
        _ = await pollUntil(within: 10) { stub.waiting > 0 }   // time this test got to run: a busy main actor must not fail it
        try #require(stub.waiting == 1)
        r.reset()                                                               // New → Discard
        let fresh = String(repeating: "my new notes after New. ", count: 20)
        r.userEdit(NSRange(location: 0, length: 0), fresh)                     // version 1 again
        stub.release()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!r.document.text.contains("discarded point"))
        #expect(r.document.text == fresh)
    }
}
