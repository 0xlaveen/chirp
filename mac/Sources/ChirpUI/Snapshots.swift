import AppKit
import ChirpCore
import SwiftUI

/// Offscreen rendering of every HUD state, the Settings window and the menu-bar menu, for UI review without
/// launching the app. It draws views into bitmaps only: no window is shown, and it never touches the microphone,
/// Accessibility, the pasteboard, the system settings store or any TCC-gated API. All inputs are synthetic.
@MainActor
public enum Snapshots {
    public struct Scenario {
        public let name: String
        let make: () -> NSView
    }

    public static let appearances: [(name: String, appearance: NSAppearance.Name)] = [
        ("light", .aqua), ("dark", .darkAqua),
    ]

    // MARK: HUD

    private static let sentence = "Please move the standup to three thirty and let everyone know"

    static func hud(_ name: String, _ configure: @escaping (HUDModel) -> Void) -> Scenario {
        Scenario(name: "hud-\(name)") {
            let model = HUDModel()
            model.reduceMotion = true
            configure(model)
            return NSHostingView(rootView: SnapshotBackdrop { HUDView(model: model) })
        }
    }

    private static func final(corrected: Bool = false) -> FinalResult {
        corrected ? FinalResult(text: "Move the standup to 3:30.", raw: "move the standup to three thirty", corrected: true)
                  : FinalResult(text: "Move the standup to 3:30.")
    }

    private static func applyOutcome(_ outcome: InsertionOutcome, final: FinalResult, offerRaw: Bool = true, to m: HUDModel) {
        let p = OutcomePresentation.of(outcome, final: final, offerRaw: offerRaw)
        m.status = p.status; m.isError = p.isError; m.showUseRaw = p.showUseRaw; m.cleaned = p.cleaned
    }

    public static var hudScenarios: [Scenario] {
        let (stable, tail) = splitPartial(text: sentence + " about the release", stable: sentence)
        let long = Array(repeating: "and then we should also check the rollout plan with the whole team", count: 5).joined(separator: ", ")
        return [
            hud("connecting") { $0.status = "Connecting…" },
            hud("listening") { $0.status = "Listening"; $0.level = 0.12; $0.stable = stable; $0.unstable = tail },
            hud("listening-no-text") { $0.status = "Listening"; $0.level = 0.05 },
            hud("listening-unstable-only") { $0.status = "Listening"; $0.level = 0.2; $0.unstable = "so the first words are" },
            hud("listening-multiline") { $0.status = "Listening"; $0.level = 0.16; $0.stable = long; $0.unstable = " and finally" },
            hud("finalizing") { $0.status = "Finalizing"; $0.stable = sentence; $0.unstable = " about the release" },
            hud("inserted") { applyOutcome(.inserted(.ax), final: final(), to: $0) },
            hud("inserted-paste") { applyOutcome(.inserted(.paste), final: final(), to: $0) },
            hud("correction-use-raw") {
                applyOutcome(.inserted(.ax), final: final(corrected: true), to: $0)
                $0.onUseRaw = {}
            },
            hud("cleaned-no-raw-button") { applyOutcome(.inserted(.ax), final: final(corrected: true), offerRaw: false, to: $0) },
            hud("copied") { applyOutcome(.copied, final: final(), to: $0) },
            hud("unverified-ax") { applyOutcome(.insertedUnverified, final: final(), to: $0) },
            hud("secure-field") { applyOutcome(.refusedSecure, final: final(), to: $0) },
            hud("no-mic-signal") { $0.status = "No microphone signal"; $0.isError = true },
            hud("error-long") {
                $0.status = "Server rejected the token (check ~/.config/chirp/token) — then restart dictation"
                $0.isError = true
            },
            hud("debug-badge") { $0.status = "Listening"; $0.level = 0.1; $0.debugRetention = true; $0.stable = stable },
            hud("debug-use-raw") {
                applyOutcome(.inserted(.ax), final: final(corrected: true), to: $0)
                $0.debugRetention = true
            },
        ]
    }

    // MARK: Settings and menu

    public static var settingsScenarios: [Scenario] {
        func form(_ name: String, _ configure: (inout SettingsState) -> Void) -> Scenario {
            var state = SettingsState()
            configure(&state)
            return Scenario(name: "settings-\(name)") {
                let form = SettingsForm(state)
                form.view.setFrameSize(form.view.fittingSize)
                return form.view
            }
        }
        return [
            form("ready") { $0.launch = .on; $0.serverStatus = "parakeet-mlx:tdt-0.6b-v2" },
            form("needs-setup") {
                $0.tokenPresent = false; $0.micGranted = false; $0.accessibilityGranted = false
                $0.launch = .unavailable; $0.serverURL = "https://mainframe.example.ts.net/chirp"
                $0.serverStatus = "Unreachable"; $0.serverStatusTone = .error
            },
        ]
    }

    private static let boya = AudioInput(uid: "boya", name: "BOYA CM40")
    private static let studio = AudioInput(uid: "studio", name: "Studio Display Microphone")

    public static var menuScenarios: [Scenario] {
        func menu(_ name: String, _ configure: (inout MenuInputs) -> Void, submenu: String? = nil) -> Scenario {
            var inputs = MenuInputs()
            inputs.inputs = [boya, studio]
            inputs.defaultInput = boya
            configure(&inputs)
            var entries = MenuContent.entries(inputs)
            if let submenu { entries = entries.first { $0.title == submenu }?.submenu ?? [] }
            return Scenario(name: "menu-\(name)") { NSHostingView(rootView: SnapshotBackdrop { MenuPreview(entries: entries) }) }
        }
        let local = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true, correction: "available", correctionLeavesMachine: false)
        let remote = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true, debugRetention: true, correction: "available",
                            correctionLeavesMachine: true, correctionHost: "llm.example.com")
        return [
            menu("idle") { $0.health = local },
            menu("listening-cleanup") { $0.state = .listening; $0.health = local; $0.cleanupOn = true },
            menu("debug-remote-cleanup") {
                $0.health = remote; $0.debugRetention = true; $0.cleanupOn = true; $0.showRawAfterCleanup = false
                $0.chosenInputUID = "studio"
            },
            menu("cleanup-off-on-server") { $0.health = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true, correction: "off") },
            menu("server-unreachable") {
                $0.healthError = "Server unreachable at 127.0.0.1"; $0.serverURL = "https://mainframe.example.ts.net/chirp"
            },
            menu("permissions-needed") {
                $0.health = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true)
                $0.micGranted = false; $0.accessibilityGranted = false
                $0.launch = .on; $0.launchError = "Operation not permitted"
            },
            menu("error") {
                $0.state = .error("Microphone access denied — enable it in System Settings")
                $0.health = local; $0.micGranted = false; $0.inputs = []; $0.defaultInput = nil
            },
            menu("input-picker", { $0.health = local; $0.chosenInputUID = "studio" }, submenu: "Input Device"),
        ]
    }

    public static var allScenarios: [Scenario] { hudScenarios + settingsScenarios + menuScenarios }

    // MARK: rendering

    /// Renders `scenario` at 2x under `appearance` into PNG data.
    public static func png(_ scenario: Scenario, appearance name: NSAppearance.Name) -> Data? {
        let view = scenario.make()
        let appearance = NSAppearance(named: name)!
        view.appearance = appearance
        let size = view.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        view.setFrameSize(size)
        // An AppKit control tree has no window of its own; give Settings the opaque background a window has.
        let host = NSBox(frame: NSRect(origin: .zero, size: size))
        host.boxType = .custom
        host.borderWidth = 0
        host.contentViewMargins = .zero
        host.fillColor = scenario.name.hasPrefix("settings-") ? .windowBackgroundColor : .clear
        host.appearance = appearance
        host.contentView = view
        host.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes `<scenario>-<appearance>.png` for every scenario and appearance; returns the files written.
    @discardableResult
    public static func render(to directory: URL, scenarios: [Scenario]? = nil) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for scenario in scenarios ?? allScenarios {
            for (label, appearance) in appearances {
                guard let data = png(scenario, appearance: appearance) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "could not render \(scenario.name)"])
                }
                let url = directory.appendingPathComponent("\(scenario.name)-\(label).png")
                try data.write(to: url)
                written.append(url)
            }
        }
        return written
    }
}

/// A desktop-like backdrop so the translucent HUD and the menu read as they do on screen.
private struct SnapshotBackdrop<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        // Solid on purpose: a flat mid-tone keeps the PNGs small and is a fair contrast case for the material.
        content.padding(14).background(Color(red: 0.45, green: 0.52, blue: 0.66))
    }
}

/// The menu-bar menu's content laid out like a menu. The real `NSMenu` chrome cannot be drawn offscreen, so rows are
/// approximated; the header block is the real `MenuHeaderView`.
private struct MenuPreview: View {
    let entries: [MenuEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .header(let head, let lines): HeaderBlock(head: head, lines: lines)
                case .entry(let e): row(e)
                }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .frame(minWidth: 300, alignment: .leading)
        .fixedSize()
        // Solid, like the backdrop: a material over it would be noisy and bloat the PNGs.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.12)))
    }

    private enum Block { case header(MenuEntry, [MenuEntry]), entry(MenuEntry) }

    /// The header row and the status lines after it form one block, as in the real menu.
    private var blocks: [Block] {
        var out: [Block] = []
        var i = 0
        while i < entries.count {
            let e = entries[i]
            i += 1
            guard e.showsAppIcon else { out.append(.entry(e)); continue }
            let start = i
            while i < entries.count, !entries[i].isSeparator { i += 1 }
            out.append(.header(e, Array(entries[start..<i])))
        }
        return out
    }

    @ViewBuilder private func row(_ e: MenuEntry) -> some View {
        if e.isSeparator {
            Divider().padding(.vertical, 4).padding(.horizontal, 6)
        } else if e.isHeader {
            Text(e.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 1)
        } else {
            let enabled = e.action != nil || e.submenu != nil
            HStack(spacing: 7) {
                Text(e.mark == .on ? "✓" : e.mark == .mixed ? "–" : "").frame(width: 12)
                icon(e).frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.title).font(.system(size: 13)).foregroundStyle(color(e))
                    if let sub = e.subtitle { Text(sub).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 16)
                if let k = e.keyEquivalent { Text("⌘" + k.uppercased()).font(.system(size: 13)).foregroundStyle(.secondary) }
                if e.submenu != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            // Like AppKit, a disabled row is dimmed.
            .opacity(enabled ? 1 : 0.5)
        }
    }

    @ViewBuilder private func icon(_ e: MenuEntry) -> some View {
        if let name = e.symbol {
            Image(systemName: name).font(.system(size: name == "circle.fill" ? 8 : 13)).foregroundStyle(tint(e.symbolTone ?? e.tone))
        }
    }

    private func tint(_ tone: MenuEntry.Tone) -> Color {
        switch tone {
        case .normal: .primary
        case .ok: .green
        case .active: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }

    private func color(_ e: MenuEntry) -> Color {
        switch e.tone {
        case .error: .red
        case .warning: .orange
        default: .primary
        }
    }
}

private struct HeaderBlock: NSViewRepresentable {
    let head: MenuEntry
    let lines: [MenuEntry]

    func makeNSView(context: Context) -> MenuHeaderView {
        MenuHeaderView(title: head.title, hint: head.subtitle, lines: lines, icon: Self.standIn)
    }
    func updateNSView(_ view: MenuHeaderView, context: Context) {}
    /// The app icon only exists in the bundled app; the snapshots draw the bird symbol in its place.
    private static var standIn: NSImage? {
        NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .regular).applying(.init(paletteColors: [.systemIndigo])))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuHeaderView, context: Context) -> CGSize? {
        CGSize(width: max(nsView.fittingSize.width, proposal.width ?? 0), height: nsView.fittingSize.height)
    }
}
