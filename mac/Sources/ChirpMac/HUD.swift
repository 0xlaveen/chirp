import AppKit
import ChirpCore
import Observation
import SwiftUI

@MainActor @Observable
final class HUDModel {
    var status = ""
    var stable = ""
    var unstable = ""
    var level: Float = 0
    var debugRetention = false
    var isError = false
    var showUseRaw = false
    var reduceMotion = false
    var onUseRaw: (() -> Void)?

    func reset() {
        status = ""; stable = ""; unstable = ""; level = 0
        isError = false; showUseRaw = false; onUseRaw = nil
    }
}

struct HUDView: View {
    let model: HUDModel
    let onSize: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LevelMeter(level: model.level, animated: !model.reduceMotion)
                    .accessibilityHidden(true)
                Text(model.status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.isError ? Color.red : Color.secondary)
                Spacer(minLength: 0)
                if model.showUseRaw {
                    Button("Use raw") { model.onUseRaw?() }.buttonStyle(.borderless).font(.system(size: 12, weight: .semibold))
                }
            }
            if model.debugRetention {
                Text("DEBUG: recordings kept")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            if !model.stable.isEmpty || !model.unstable.isEmpty {
                (Text(model.stable) + Text(model.unstable).foregroundStyle(.secondary))
                    .font(.system(size: 15))
                    .lineLimit(4)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .accessibilityElement(children: .contain)
        .padding(14)
        .frame(width: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        .padding(10)   // room for the shadow inside the panel
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onSize)
    }
}

private struct LevelMeter: View {
    let level: Float
    let animated: Bool
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                let on = Float(i) / 8 < min(1, level * 6)
                Capsule().fill(on ? Color.green : Color.primary.opacity(0.15)).frame(width: 3, height: 12)
            }
        }
        .animation(animated ? .linear(duration: 0.05) : nil, value: level)
    }
}

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
