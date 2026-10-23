import AppKit
import SwiftUI
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// The Notes window at its minimum width: the Record/Stop label stays on one line in every state, and the structuring
/// chip shows its whole host (#65).
@MainActor
@Suite struct NotesLayoutTests {
    private func lay(_ configure: (NotesModel) -> Void, width: CGFloat = NotesViewMetrics.minimumSize.width) async -> NotesModel {
        let model = NotesModel()
        model.elapsed = 192
        model.document = Snapshots.demoNotes()
        configure(model)
        let host = NSHostingView(rootView: NotesView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: width, height: NotesViewMetrics.minimumSize.height + 160)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        return model
    }

    private func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }

    @Test func theRecordLabelIsOneLineInEveryStateAtTheMinimumWidth() async {
        let states: [(String, NotesRecorderState)] = [
            ("idle", .idle), ("starting", .starting), ("recording", .recording), ("paused", .paused), ("stopping", .stopping),
            ("stopped", .stopped), ("error", .error("Notes stopped: The microphone stopped — check the input device")),
        ]
        for (name, state) in states {
            let model = await lay { $0.state = state; $0.level = 0.5 }
            let label = model.probe.recordLabel
            let word = state.isLive ? "Stop" : "Record"
            #expect(label.width + 1 >= textWidth(word, size: 12, weight: .medium), "\(name): label cut short")
            #expect(label.height > 0 && label.height < 20, "\(name): label wraps (\(label.height) pt high)")
        }
    }

    @Test func theRecordLabelIsOneLineWithALongStatusAndTheHint() async {
        let model = await lay {
            $0.state = .stopping
            $0.reorganizeStatus = .organizing(step: 12, of: 14)
            $0.finishingElapsed = 99
            $0.dictationKey = "⌃⌥ Control Option"
        }
        #expect(model.probe.recordLabel.height > 0 && model.probe.recordLabel.height < 20)
    }

    @Test func theStructuringChipShowsTheWholeHostAtTheMinimumWidth() async {
        for host in ["llm.example.com", "inference-gateway.eu-west.internal.example.com"] {
            let model = await lay { $0.structuringHost = host; $0.state = .recording; $0.debugRetention = true }
            let chip = model.probe.structuringChip
            #expect(chip.width >= textWidth(NotesStatus.structuringChip(host), size: 10, weight: .medium) + 14, "\(host): \(chip.width)")
            #expect(chip.height < 22)
        }
    }

    @Test func noChipWhenStructuringStaysOnThisMac() async {
        let model = await lay { $0.structuringHost = nil }
        #expect(model.probe.structuringChip == .zero)
    }
}
