import AppKit
import ChirpUI
import SwiftUI

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A non-activating floating panel: it shows partial text without ever taking focus from the target app.
@MainActor
final class HUDController {
    let model = HUDModel()
    private var panel: HUDPanel?
    private var hideTask: Task<Void, Never>?
    private var size = CGSize(width: 480, height: 80)

    private func makePanel() -> HUDPanel {
        let p = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: HUDView(model: model) { [weak self] s in self?.resize(to: s) })
        host.sizingOptions = []
        p.contentView = host
        return p
    }

    func show() {
        hideTask?.cancel()
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let p = panel ?? makePanel()
        panel = p
        position(p)
        p.orderFrontRegardless()
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        model.reset()
    }

    /// Hide after a delay unless something else is shown first.
    func hide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Has VoiceOver speak a status change; the HUD never takes focus, so it would otherwise stay silent.
    func announce(_ text: String) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func resize(to s: CGSize) {
        size = s
        guard let p = panel else { return }
        p.setContentSize(s)
        position(p)
    }

    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 4)
        p.setFrameOrigin(origin)
    }
}
