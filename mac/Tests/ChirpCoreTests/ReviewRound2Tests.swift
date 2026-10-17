import Foundation
import Testing
@testable import ChirpCore

/// Only injected fakes: no AX, pasteboard, microphone, or socket access.
@MainActor
@Suite struct ReviewRound2Tests {
    @Test func overlappingPastesPreserveOriginalClipboard() async {
        let board = FakePasteboard()
        var sleepers: [CheckedContinuation<Void, Never>] = []
        let inserter = TextInserter(env: InsertionEnvironment(
            secureInputEnabled: { false }, axTrusted: { true },
            frontmostBundleID: { "com.apple.Terminal" },
            axInsert: { _ in .notAttempted }, axReplace: { _, _, _ in false },
            postPaste: { true }, postUndo: { true },
            sleep: { _ in await withCheckedContinuation { sleepers.append($0) } }
        ), pasteboard: board)
        _ = await inserter.insert("synthetic first")
        _ = await inserter.insert("synthetic second")
        // Both restore tasks must reach the injected barrier before either is resumed.
        while sleepers.count < 2 { await Task.yield() }
        let pending = sleepers
        sleepers.removeAll()
        for sleeper in pending { sleeper.resume() }
        await inserter.settle()
        withKnownIssue("R2-03: second paste snapshots the first transient transcript") {
            #expect(board.text == "user clipboard")
        }
    }

    @Test func useRawDoesNotUndoInAnotherApplication() async {
        let system = FakeSystem(), board = FakePasteboard()
        system.bundle = "com.apple.Terminal"
        let inserter = system.inserter(board: board)
        _ = await inserter.insert("Synthetic corrected.")
        await inserter.settle()
        system.bundle = "com.apple.TextEdit"
        system.calls.removeAll()
        _ = await inserter.replaceLast(with: "synthetic raw")
        withKnownIssue("R2-02: paste undo has no target identity check") {
            #expect(system.calls.isEmpty)
        }
    }

    @Test func useRawDoesNotUndoInSecureInput() async {
        let system = FakeSystem(), board = FakePasteboard()
        system.bundle = "com.apple.Terminal"
        let inserter = system.inserter(board: board)
        _ = await inserter.insert("Synthetic corrected.")
        await inserter.settle()
        system.secure = true
        system.calls.removeAll()
        _ = await inserter.replaceLast(with: "synthetic raw")
        withKnownIssue("R2-02: Undo is posted before the secure-input guard") {
            #expect(system.calls.isEmpty)
        }
    }
}
