import Foundation
import Testing
@testable import ChirpCore

@MainActor
final class FakePasteboard: PasteboardClient {
    var changeCount = 1
    var items: [PasteboardItem] = [["public.utf8-plain-text": Data("user clipboard".utf8)]]
    var lastWriteTransient: Bool?
    func snapshot() -> [PasteboardItem] { items }
    func write(text: String, transient: Bool) -> Int {
        items = [["public.utf8-plain-text": Data(text.utf8)]]
        lastWriteTransient = transient
        changeCount += 1
        return changeCount
    }
    func restore(_ saved: [PasteboardItem]) { items = saved; changeCount += 1 }
    var text: String? { items.first?["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) } }
}

@MainActor
struct Probe {
    var secure = false, trusted = true, bundle: String? = "com.apple.TextEdit"
    var axResult = true, pasteResult = true
    var calls: [String] = []
}

@MainActor
@Suite struct InsertionTests {
    static func make(_ probe: Probe, board: FakePasteboard, calls: CallLog) -> TextInserter {
        let env = InsertionEnvironment(
            secureInputEnabled: { probe.secure }, axTrusted: { probe.trusted },
            frontmostBundleID: { probe.bundle },
            axInsert: { _ in calls.items.append("ax"); return probe.axResult },
            postPaste: { calls.items.append("paste"); return probe.pasteResult },
            sleep: { _ in })
        return TextInserter(env: env, pasteboard: board)
    }

    @MainActor final class CallLog { var items: [String] = [] }

    // MARK: policy

    @Test func policyOrder() {
        #expect(InsertionPolicy.plan(secureInput: true, axTrusted: true, bundleID: nil) == .refuseSecure)
        #expect(InsertionPolicy.plan(secureInput: false, axTrusted: false, bundleID: "com.apple.TextEdit") == .try_([.copy]))
        #expect(InsertionPolicy.plan(secureInput: false, axTrusted: true, bundleID: "com.apple.TextEdit") == .try_([.ax, .paste, .copy]))
        #expect(InsertionPolicy.plan(secureInput: false, axTrusted: true, bundleID: "com.apple.Terminal") == .try_([.paste, .copy]))
        #expect(InsertionPolicy.plan(secureInput: false, axTrusted: true, bundleID: nil) == .try_([.ax, .paste, .copy]))
    }

    // MARK: inserter

    @Test func axSuccessLeavesPasteboardAlone() async {
        let board = FakePasteboard(), log = CallLog()
        let outcome = await Self.make(Probe(), board: board, calls: log).insert("hello")
        #expect(outcome == .inserted(.ax))
        #expect(log.items == ["ax"])
        #expect(board.text == "user clipboard")
    }

    @Test func fallsBackToPasteThenRestoresClipboard() async {
        let board = FakePasteboard(), log = CallLog()
        var p = Probe(); p.axResult = false
        let inserter = Self.make(p, board: board, calls: log)
        #expect(await inserter.insert("hello") == .inserted(.paste))
        #expect(log.items == ["ax", "paste"])
        #expect(board.lastWriteTransient == true)
        await inserter.settle()
        #expect(board.text == "user clipboard")
    }

    @Test func doesNotRestoreIfClipboardChangedMeanwhile() async {
        let board = FakePasteboard(), log = CallLog()
        var p = Probe(); p.bundle = "com.apple.Terminal"
        let inserter = Self.make(p, board: board, calls: log)
        _ = await inserter.insert("hello")
        #expect(log.items == ["paste"])                // terminals skip AX
        board.items = [["public.utf8-plain-text": Data("user copied something new".utf8)]]
        board.changeCount += 1                          // someone else wrote before the restore delay
        await inserter.settle()
        #expect(board.text == "user copied something new")
    }

    @Test func pasteFailureRestoresAndCopies() async {
        let board = FakePasteboard(), log = CallLog()
        var p = Probe(); p.axResult = false; p.pasteResult = false
        #expect(await Self.make(p, board: board, calls: log).insert("hello") == .copied)
        #expect(board.text == "hello")
        #expect(board.lastWriteTransient == false)     // copy-only stays on the clipboard for ⌘V
    }

    @Test func untrustedCopiesOnly() async {
        let board = FakePasteboard(), log = CallLog()
        var p = Probe(); p.trusted = false
        #expect(await Self.make(p, board: board, calls: log).insert("hello") == .copied)
        #expect(log.items.isEmpty)
    }

    @Test func secureInputRefusesAndTouchesNothing() async {
        let board = FakePasteboard(), log = CallLog()
        var p = Probe(); p.secure = true
        #expect(await Self.make(p, board: board, calls: log).insert("hello") == .refusedSecure)
        #expect(log.items.isEmpty)
        #expect(board.text == "user clipboard")
    }
}
