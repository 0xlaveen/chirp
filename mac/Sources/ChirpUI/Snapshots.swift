import AppKit
import Carbon.HIToolbox
import ChirpCore
import SwiftUI

/// Offscreen rendering of every HUD state, the Settings, setup and About windows and the menu-bar menu, for UI review without
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

    /// The app icon when the source tree's `Assets/AppIcon.png` is there (a development checkout), else a bird symbol:
    /// the icon only exists in the bundled app, and the snapshots never read the app bundle or the installed app.
    static let appIcon: NSImage? = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets/AppIcon.png")
        if let image = NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .regular).applying(.init(paletteColors: [.systemIndigo])))
    }()

    static func hud(_ name: String, _ configure: @escaping (HUDModel) -> Void) -> Scenario {
        Scenario(name: "hud-\(name)") {
            let model = HUDModel()
            // No window to blur through offscreen, so the HUD draws its flat stand-in for the material.
            model.flatSurface = true
            configure(model)
            return NSHostingView(rootView: SnapshotBackdrop { HUDView(model: model) })
        }
    }

    private static let rawSentence = "move the standup to three thirty and uh let everyone know"
    private static let cleanedSentence = "Move the standup to 3:30 and let everyone know."

    private static func final(corrected: Bool = false) -> FinalResult {
        corrected ? FinalResult(text: "Move the standup to 3:30.", raw: "move the standup to three thirty", corrected: true)
                  : FinalResult(text: "Move the standup to 3:30.")
    }

    private static func applyOutcome(_ outcome: InsertionOutcome, final: FinalResult, offerRaw: Bool = true, to m: HUDModel) {
        let p = OutcomePresentation.of(outcome, final: final, offerRaw: offerRaw)
        m.status = p.status; m.indicator = p.indicator; m.isError = p.isError; m.showUseRaw = p.showUseRaw; m.cleaned = p.cleaned
        m.keptOriginal = p.keptOriginal
    }

    public static var hudScenarios: [Scenario] {
        let (stable, tail) = splitPartial(text: sentence + " about the release", stable: sentence)
        let long = Array(repeating: "and then we should also check the rollout plan with the whole team", count: 5).joined(separator: ", ")
        return [
            hud("connecting") { $0.status = HUDStatus.connecting },
            hud("listening") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.8); $0.stable = stable; $0.unstable = tail },
            hud("listening-no-text") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.45) },
            hud("listening-unstable-only") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 1); $0.unstable = "so the first words are" },
            hud("listening-multiline") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.7); $0.stable = long; $0.unstable = " and finally" },
            hud("listening-reduce-motion") { $0.status = HUDStatus.listening; $0.reduceMotion = true; $0.stable = stable; $0.unstable = tail },
            hud("listening-contrast") {
                $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.8); $0.increaseContrast = true
                $0.stable = stable; $0.unstable = tail
            },
            // The clean-up transition, in order: listening → finishing → polishing → changes → inserted.
            hud("flow-1-listening") {
                $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.8); $0.styleName = "Email"
                $0.stable = rawSentence; $0.unstable = ""
            },
            hud("flow-2-polishing") {
                $0.beginPolishing(raw: rawSentence, style: "Email"); $0.shimmerPhase = 0.45
            },
            hud("flow-3-diff") {
                $0.status = HUDStatus.polished; $0.indicator = .sparkle; $0.styleName = "Email"
                $0.diff = WordDiff.segments(raw: rawSentence, cleaned: cleanedSentence)
            },
            hud("flow-4-diff-fading") {
                $0.status = HUDStatus.polished; $0.indicator = .sparkle; $0.styleName = "Email"
                $0.diff = WordDiff.segments(raw: rawSentence, cleaned: cleanedSentence); $0.diffFade = 0.6
            },
            hud("flow-5-inserted") {
                applyOutcome(.inserted(.ax), final: FinalResult(text: cleanedSentence, raw: rawSentence, corrected: true), to: $0)
                $0.styleName = "Email"; $0.stable = cleanedSentence; $0.onUseRaw = {}
            },
            hud("polishing-reduce-motion") {
                $0.reduceMotion = true; $0.beginPolishing(raw: rawSentence, style: "Chat")
            },
            hud("polishing-multiline") {
                $0.beginPolishing(raw: long, style: "Notes"); $0.shimmerPhase = 0.6
            },
            hud("polishing-contrast") {
                $0.increaseContrast = true; $0.beginPolishing(raw: rawSentence, style: "Code"); $0.shimmerPhase = 0.3
            },
            hud("diff-reduce-motion") {
                $0.reduceMotion = true; $0.status = HUDStatus.polished; $0.indicator = .sparkle; $0.styleName = "Chat"
                $0.diff = WordDiff.segments(raw: rawSentence, cleaned: cleanedSentence)
            },
            hud("kept-original") {
                applyOutcome(.inserted(.ax), final: FinalResult(text: rawSentence, corrected: false, correctionError: "timeout"), to: $0)
                $0.styleName = "Email"; $0.stable = rawSentence
            },
            hud("finalizing") { $0.status = HUDStatus.finishing; $0.stable = sentence; $0.unstable = " about the release" },
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
            hud("no-mic-signal") { $0.status = "No microphone signal"; $0.isError = true; $0.indicator = .warning },
            hud("error-long") {
                $0.status = "Server rejected the token (check ~/.config/chirp/token) — then restart dictation"
                $0.isError = true; $0.indicator = .warning
            },
            hud("debug-badge") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.5); $0.debugRetention = true; $0.stable = stable },
            hud("debug-use-raw") {
                applyOutcome(.inserted(.ax), final: final(corrected: true), to: $0)
                $0.debugRetention = true
            },
        ]
    }

    // MARK: Settings and menu

    /// The server's styles with prompt text, as `GET /v1/correction/profiles` would return them.
    static let samplePrompts: [CorrectionProfile] = CorrectionProfile.builtIn.map { p in
        var p = p
        switch p.id {
        case "default": p.prompt = "Fix punctuation, capitalisation and obvious slips. Keep the speaker’s words and order."
        case "chat": p.prompt = "Casual messages: lowercase is fine and a short message needs no final period."
        case "email": p.prompt = "Polished, complete sentences with proper punctuation. Add nothing the speaker did not say."
        case "code": p.prompt = "Keep identifiers, symbols and casing exactly as spoken. Do not expand abbreviations."
        case "notes": p.prompt = "Turn spoken lists into short lines or bullets. Keep every item."
        default: break
        }
        return p
    }

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
            form("cleanup-custom") {
                $0.cleanupStyle = "custom"; $0.insertRawFirst = true; $0.launch = .on; $0.serverStatus = "parakeet-mlx:tdt-0.6b-v2"
                $0.catalog = StyleCatalog(profiles: samplePrompts, source: .live)
                $0.editingStyle = "custom"
                $0.stylePrompts = ["custom": "Write like a short, friendly note to a teammate. Keep product names exactly as spoken and never add facts I did not say."]
                $0.appStyles = [AppStyleRule(bundleID: "com.tinyspeck.slackmacgap", profile: "chat"),
                                AppStyleRule(bundleID: "com.apple.mail", profile: "custom"),
                                AppStyleRule(bundleID: "com.apple.dt.Xcode", profile: "code")]
            },
            form("cleanup-prompt-default") {
                $0.launch = .on; $0.serverStatus = "parakeet-mlx:tdt-0.6b-v2"
                $0.catalog = StyleCatalog(profiles: samplePrompts, source: .live)
                $0.editingStyle = "email"
            },
            form("cleanup-prompt-edited") {
                $0.launch = .on; $0.serverStatus = "parakeet-mlx:tdt-0.6b-v2"
                $0.catalog = StyleCatalog(profiles: samplePrompts, source: .live)
                $0.editingStyle = "chat"
                $0.stylePrompts = ["chat": "Casual and brief. Lowercase is fine. Keep emoji names as spoken, like “thumbs up”."]
            },
            form("cleanup-prompt-offline") {
                $0.launch = .on; $0.serverStatus = "Unreachable"; $0.serverStatusTone = .error
                $0.catalog = StyleCatalog(profiles: samplePrompts, source: .cached)
                $0.editingStyle = "code"
            },
            form("cleanup-notes-no-styles") {
                $0.cleanupStyle = "notes"; $0.serverOffersStyles = false; $0.launch = .on; $0.serverStatus = "parakeet-mlx:tdt-0.6b-v2"
            },
            form("sounds-pack") {
                $0.soundsEnabled = true; $0.soundPack = .chirp; $0.soundVolume = 0.6
                $0.launch = .on; $0.serverStatus = "parakeet-mlx:tdt-0.6b-v2"
            },
            form("sounds-custom") {
                $0.soundsEnabled = true; $0.soundPack = .custom; $0.soundVolume = 0.4
                $0.customStart = CustomSound(fileName: "custom-start-1a2b3c4d.m4a", displayName: "Doorbell chime.m4a", duration: 1.2)
                $0.customStop = CustomSound(fileName: "custom-stop-5e6f7a8b.wav", displayName: "soft-tap.wav", duration: 0.18)
                $0.launch = .on; $0.serverStatus = "parakeet-mlx:tdt-0.6b-v2"
            },
            form("custom-hotkey-sounds") {
                $0.hotkey = .custom(keyCode: 0x0F, modifiers: UInt32(controlKey | optionKey | cmdKey))   // ⌃⌥⌘R
                $0.soundsEnabled = true; $0.launch = .on; $0.serverStatus = "parakeet-mlx:tdt-0.6b-v2"
            },
            Scenario(name: "settings-hotkey-rejected") {
                let form = SettingsForm(SettingsState())
                // As if ⌥Space had just been pressed in the recorder (set directly: no event monitor offscreen).
                form.recorder.apply(.rejected(.optionOnly))
                form.view.setFrameSize(form.view.fittingSize)
                return form.view
            },
            form("needs-setup") {
                $0.tokenPresent = false; $0.micGranted = false; $0.accessibilityGranted = false
                $0.launch = .unavailable; $0.serverURL = "https://mainframe.example.ts.net/chirp"
                $0.serverStatus = "Unreachable"; $0.serverStatusTone = .error
            },
        ]
    }

    // MARK: setup and About

    public static var onboardingScenarios: [Scenario] {
        func step(_ name: String, _ state: OnboardingState) -> Scenario {
            Scenario(name: "onboarding-\(name)") {
                let view = OnboardingView(icon: appIcon)
                view.apply(state)
                return view
            }
        }
        func checks(_ configure: (inout OnboardingChecks) -> Void) -> OnboardingChecks {
            var c = OnboardingChecks()
            configure(&c)
            return c
        }
        return [
            step("welcome", OnboardingState(step: .welcome)),
            step("microphone-needed", OnboardingState(step: .microphone, checks: checks { $0.microphone = .notAsked })),
            step("microphone-blocked", OnboardingState(step: .microphone, checks: checks { $0.microphone = .denied })),
            step("accessibility-needed", OnboardingState(step: .accessibility, checks: checks { $0.accessibility = false })),
            step("server-ready", OnboardingState(step: .server, checks: checks { $0.server = .ready(engine: "parakeet-mlx:tdt-0.6b-v2") })),
            step("server-unreachable", OnboardingState(step: .server, checks: checks { $0.server = .unreachable(host: "127.0.0.1") })),
            step("try-it-waiting", OnboardingState(step: .tryIt)),
            step("try-it-success", OnboardingState(step: .tryIt, heardHotkey: true)),
        ]
    }

    public static var aboutScenarios: [Scenario] {
        [Scenario(name: "about") { AboutView(icon: appIcon, info: AboutInfo(version: "0.1.0", build: "1")) }]
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
        let local = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true, correction: "available", correctionLeavesMachine: false,
                           correctionProfiles: CorrectionProfile.builtIn)
        let remote = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true, debugRetention: true, correction: "available",
                            correctionLeavesMachine: true, correctionHost: "llm.example.com",
                            correctionProfiles: CorrectionProfile.builtIn)
        return [
            menu("idle") { $0.health = local },
            menu("listening-cleanup") { $0.state = .listening; $0.health = local; $0.cleanupOn = true; $0.styleID = "email" },
            menu("polishing") { $0.state = .correcting; $0.health = local; $0.cleanupOn = true },
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
            menu("use-raw-offer") { $0.health = local; $0.cleanupOn = true; $0.rawOfferOpen = true; $0.rawOfferKey = "⌃⌥Z" },
            menu("style", { $0.health = local; $0.cleanupOn = true; $0.styleID = "email" }, submenu: "Style"),
            menu("style-custom", { $0.health = local; $0.cleanupOn = true; $0.styleID = "custom" }, submenu: "Style"),
            menu("sounds", { $0.health = local; $0.soundsEnabled = true; $0.soundPack = .chirp }, submenu: "Sounds"),
            menu("input-picker", { $0.health = local; $0.chosenInputUID = "studio" }, submenu: "Input Device"),
        ]
    }

    public static var allScenarios: [Scenario] { hudScenarios + settingsScenarios + onboardingScenarios + aboutScenarios + menuScenarios }

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
        let isWindow = ["settings-", "onboarding-", "about"].contains { scenario.name.hasPrefix($0) }
        host.fillColor = isWindow ? .windowBackgroundColor : .clear
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
    /// The real icon would add ~100 KB to every menu PNG; the menu snapshots draw the bird symbol in its place.
    private static var standIn: NSImage? {
        NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .regular).applying(.init(paletteColors: [.systemIndigo])))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuHeaderView, context: Context) -> CGSize? {
        CGSize(width: max(nsView.fittingSize.width, proposal.width ?? 0), height: nsView.fittingSize.height)
    }
}
