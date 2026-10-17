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
        /// A tab's content, as the preferences window shows it under the toolbar.
        func form(_ name: String, _ tab: SettingsTab, _ configure: (inout SettingsState) -> Void = { _ in }) -> Scenario {
            var state = SettingsState()
            state.launch = .on; state.serverStatus = "parakeet-mlx:tdt-0.6b-v2"
            configure(&state)
            return Scenario(name: "settings-\(tab.rawValue)-\(name)") {
                let form = SettingsForm(state)
                let view = form.view(for: tab)
                view.setFrameSize(form.fittingSize(for: tab))
                return view
            }
        }
        let styled: (inout SettingsState) -> Void = {
            $0.cleanupEnabled = true
            $0.catalog = StyleCatalog(profiles: samplePrompts, source: .live)
            $0.cleanupDetail = "Runs on this Mac: tidies punctuation and wording before the text is inserted."
        }
        return [
            form("ready", .general) { _ in },
            form("custom-hotkey", .general) { $0.hotkey = .custom(keyCode: 0x0F, modifiers: UInt32(controlKey | optionKey | cmdKey)) },   // ⌃⌥⌘R
            form("login-unavailable", .general) { $0.launch = .unavailable },
            Scenario(name: "settings-general-hotkey-rejected") {
                let form = SettingsForm(SettingsState())
                // As if ⌥Space had just been pressed in the recorder (set directly: no event monitor offscreen).
                form.recorder.apply(.rejected(.optionOnly))
                let view = form.view(for: .general)
                view.setFrameSize(form.fittingSize(for: .general))
                return view
            },
            form("off", .sounds) { _ in },
            form("pack", .sounds) { $0.soundsEnabled = true; $0.soundPack = .chirp; $0.soundVolume = 0.6 },
            form("custom", .sounds) {
                $0.soundsEnabled = true; $0.soundPack = .custom; $0.soundVolume = 0.4
                $0.customStart = CustomSound(fileName: "custom-start-1a2b3c4d.m4a", displayName: "Doorbell chime.m4a", duration: 1.2)
                $0.customStop = CustomSound(fileName: "custom-stop-5e6f7a8b.wav", displayName: "soft-tap.wav", duration: 0.18)
            },
            form("default", .cleanup) { styled(&$0); $0.editingStyle = "default" },
            form("custom", .cleanup) {
                styled(&$0)
                $0.cleanupStyle = "custom"; $0.insertRawFirst = true; $0.editingStyle = "custom"
                $0.stylePrompts = ["custom": "Write like a short, friendly note to a teammate. Keep product names exactly as spoken and never add facts I did not say."]
                $0.appStyles = [AppStyleRule(bundleID: "com.tinyspeck.slackmacgap", profile: "chat"),
                                AppStyleRule(bundleID: "com.apple.mail", profile: "custom"),
                                AppStyleRule(bundleID: "com.apple.dt.Xcode", profile: "code")]
            },
            form("prompt-default", .cleanup) { styled(&$0); $0.editingStyle = "email" },
            form("prompt-edited", .cleanup) {
                styled(&$0)
                $0.editingStyle = "chat"; $0.showChanges = true
                $0.stylePrompts = ["chat": "Casual and brief. Lowercase is fine. Keep emoji names as spoken, like “thumbs up”."]
            },
            form("prompt-offline", .cleanup) {
                styled(&$0)
                $0.serverStatus = "Unreachable"; $0.serverStatusTone = .error
                $0.catalog = StyleCatalog(profiles: samplePrompts, source: .cached)
                $0.editingStyle = "code"
            },
            form("no-styles", .cleanup) {
                $0.cleanupEnabled = true; $0.cleanupStyle = "notes"; $0.serverOffersStyles = false
            },
            form("unavailable", .cleanup) {
                $0.cleanupDetail = "The server has clean-up turned off; see the README to enable it."; $0.cleanupAvailable = false
            },
            form("ready", .server) { _ in },
            form("unreachable", .server) {
                $0.tokenPresent = false; $0.serverURL = "https://mainframe.example.ts.net/chirp"
                $0.serverStatus = "Unreachable"; $0.serverStatusTone = .error
            },
            form("granted", .permissions) { _ in },
            form("missing", .permissions) { $0.micGranted = false; $0.accessibilityGranted = false },
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
        func menu(_ name: String, highlighting: String? = nil, _ configure: (inout MenuInputs) -> Void) -> Scenario {
            var inputs = MenuInputs()
            inputs.inputs = [boya, studio]
            inputs.defaultInput = boya
            configure(&inputs)
            let header = MenuContent.header(inputs)
            let entries = MenuContent.entries(inputs)
            return Scenario(name: "menu-\(name)") { MenuPanelView(header: header, entries: entries, highlighting: highlighting) }
        }
        func submenu(_ name: String, of title: String, _ configure: (inout MenuInputs) -> Void) -> Scenario {
            var inputs = MenuInputs()
            inputs.inputs = [boya, studio]
            inputs.defaultInput = boya
            configure(&inputs)
            let rows = MenuContent.entries(inputs).first { $0.title == title }?.submenu ?? []
            return Scenario(name: "menu-\(name)") { MenuPanelView(header: nil, entries: rows, native: true) }
        }
        let local = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true, correction: "available", correctionLeavesMachine: false,
                           correctionProfiles: CorrectionProfile.builtIn)
        let remote = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true, debugRetention: true, correction: "available",
                            correctionLeavesMachine: true, correctionHost: "llm.example.com",
                            correctionProfiles: CorrectionProfile.builtIn)
        return [
            menu("ready") { $0.health = local },
            menu("hover", highlighting: "Clean-up") { $0.health = local; $0.cleanupOn = true; $0.styleID = "email" },
            menu("paused") { $0.health = local; $0.paused = true; $0.hotkeyRegistered = false },
            menu("listening") { $0.state = .listening; $0.health = local; $0.cleanupOn = true; $0.styleID = "email" },
            menu("polishing") { $0.state = .correcting; $0.health = local; $0.cleanupOn = true },
            menu("debug") {
                $0.health = remote; $0.debugRetention = true; $0.cleanupOn = true
                $0.chosenInputUID = "studio"
            },
            menu("cleanup-off-on-server") { $0.health = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true, correction: "off") },
            menu("unreachable") {
                $0.healthError = "Server unreachable at 127.0.0.1"; $0.serverURL = "https://mainframe.example.ts.net/chirp"
            },
            menu("permissions-missing") {
                $0.health = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true)
                $0.micGranted = false; $0.accessibilityGranted = false
            },
            menu("error") {
                $0.state = .error("Microphone access denied — enable it in System Settings")
                $0.health = local; $0.micGranted = false; $0.inputs = []; $0.defaultInput = nil
            },
            menu("use-raw") { $0.health = local; $0.cleanupOn = true; $0.rawOfferOpen = true; $0.rawOfferKey = "⌃⌥Z" },
            menu("long-names") {
                $0.health = local; $0.chosenInputUID = "long"
                $0.inputs = [boya, AudioInput(uid: "long", name: "Studio Display Microphone (Built-in, Aggregate)")]
                $0.serverURL = "https://mainframe-with-a-very-long-name.example.ts.net/chirp"
            },
            submenu("cleanup-submenu", of: "Clean-up") { $0.health = local; $0.cleanupOn = true; $0.styleID = "email" },
            submenu("cleanup-submenu-off", of: "Clean-up") { $0.health = local },
            submenu("microphone-submenu", of: "Microphone") { $0.health = local; $0.chosenInputUID = "studio" },
            submenu("sounds-submenu", of: "Sounds") { $0.health = local; $0.soundsEnabled = true; $0.soundPack = .chirp },
            submenu("server-submenu", of: "Server") { $0.health = local },
        ]
    }

    /// The scenarios whose PNGs are committed under `docs/screenshots/mac`: the key HUD states, the menu in light and
    /// dark, one per Settings tab, and the setup window. The rest only render to a temporary directory for review.
    public static let committedNames: [String] = [
        "hud-listening", "hud-flow-2-polishing", "hud-flow-3-diff", "hud-correction-use-raw",
        "menu-ready", "menu-cleanup-submenu",
        "settings-general-ready", "settings-sounds-pack", "settings-cleanup-custom", "settings-server-ready",
        "settings-permissions-missing", "onboarding-welcome",
    ]

    public static var committedScenarios: [Scenario] {
        let all = allScenarios
        return committedNames.compactMap { name in all.first { $0.name == name } }
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

/// A desktop-like backdrop colour so the translucent HUD and the menu read as they do on screen.
private struct SnapshotBackdrop<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        // Solid on purpose: a flat mid-tone keeps the PNGs small and is a fair contrast case for the material.
        content.padding(14).background(Color(red: 0.45, green: 0.52, blue: 0.66))
    }
}

/// The menu-bar menu drawn from its real views: the header (with its switch) and the rows are the same classes the
/// live `NSMenu` uses; only the menu's own chrome (background, border, separators) is approximated, since an `NSMenu`
/// cannot be drawn offscreen. `native` is a submenu, whose rows AppKit draws itself (checkmark column, no values).
private final class MenuPanelView: NSView {
    private static let outer: CGFloat = 14
    private static let inner: CGFloat = 6
    private static let backdrop = NSColor(red: 0.45, green: 0.52, blue: 0.66, alpha: 1)

    init(header: MenuHeader?, entries: [MenuEntry], highlighting: String? = nil, native: Bool = false) {
        super.init(frame: .zero)
        var views: [NSView] = []
        var widest: CGFloat = header == nil ? 0 : MenuMetrics.minimumWidth
        if let header { views.append(MenuHeaderView(header: header)) }
        for entry in entries {
            if entry.isSeparator { views.append(MenuSeparatorView()); continue }
            if native {
                let row = SubmenuRowView(entry: entry)
                widest = max(widest, row.fittingWidth)
                views.append(row)
                continue
            }
            let row = MenuRowView(entry: entry)
            row.showsHighlight = entry.title == highlighting
            widest = max(widest, row.fittingWidth)
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let pad = Self.outer + Self.inner
        let minimum = widthAnchor.constraint(equalToConstant: widest + 2 * Self.outer)
        NSLayoutConstraint.activate([
            minimum,
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.outer),
            trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: Self.outer),
            bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: pad),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        Self.backdrop.setFill()
        bounds.fill()
        let panel = bounds.insetBy(dx: Self.outer, dy: Self.outer)
        let path = NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// A submenu row as AppKit draws it: a checkmark column, the title, dimmed when it cannot be chosen.
private final class SubmenuRowView: NSView {
    private let entry: MenuEntry

    init(entry: MenuEntry) {
        self.entry = entry
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: MenuMetrics.rowHeight))
        autoresizingMask = [.width]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: MenuMetrics.rowHeight) }

    var fittingWidth: CGFloat {
        let width = (entry.title as NSString).size(withAttributes: [.font: MenuStyle.font]).width
        return max(MenuMetrics.minimumWidth - 60, ceil(width) + 34 + MenuMetrics.trailing + 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = entry.isEnabled ? .labelColor : .disabledControlTextColor
        let height = MenuStyle.font.boundingRectForFont.height
        let y = (bounds.height - height) / 2
        if entry.mark == .on {
            ("✓" as NSString).draw(at: NSPoint(x: 14, y: y), withAttributes: [.font: MenuStyle.font, .foregroundColor: color])
        }
        (entry.title as NSString).draw(at: NSPoint(x: 34, y: y), withAttributes: [.font: MenuStyle.font, .foregroundColor: color])
    }
}
