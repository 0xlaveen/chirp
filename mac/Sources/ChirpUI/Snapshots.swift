import AppKit
import ImageIO
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

    /// The brand glyph (the operator-approved template PNG in `Assets/`), About and onboarding's hero.
    static let appIcon: NSImage? = ChirpBrand.glyph()

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

    // MARK: word waveform demo data

    /// Word timings at a natural pace with a few pauses, and levels shaped like speech inside each word (near silence
    /// between them): deterministic, so the committed PNGs are reproducible.
    static func demoWords(_ text: String, pauseAfter: Set<Int> = [], stableBefore: Int = 0) -> [WordTiming] {
        var t = 0.25
        return text.split(separator: " ").enumerated().map { i, word in
            let length = 0.12 + 0.045 * Double(word.count)
            let timing = WordTiming(text: String(word), start: t, end: t + length, stable: i < stableBefore)
            t += length + (pauseAfter.contains(i) ? 0.75 : 0.09)
            return timing
        }
    }

    static func demoLevels(for words: [WordTiming], peak: Float = 0.9) -> UtteranceLevels {
        let frames = Int(((words.last?.end ?? 0) + 0.3) / UtteranceLevels.frameDuration)
        var samples = [Float](repeating: 0, count: frames)
        for (w, word) in words.enumerated() {
            let first = Int(word.start / UtteranceLevels.frameDuration), last = Int(word.end / UtteranceLevels.frameDuration)
            for f in first...max(first, last) where f < frames {
                let x = Double(f - first) / Double(max(1, last - first))          // 0...1 across the word
                let envelope = sin(x * .pi) * (0.65 + 0.35 * sin(Double(f) * 1.7 + Double(w)))
                samples[f] = Float(max(0.08, envelope)) * peak
            }
        }
        for f in samples.indices where samples[f] == 0 { samples[f] = 0.03 + 0.02 * Float(abs(sin(Double(f) * 0.9))) }
        return UtteranceLevels(samples: samples)
    }

    static func wordWave(_ name: String, _ text: String, pauseAfter: Set<Int> = [], stableBefore: Int = 0,
                         _ configure: @escaping (HUDModel) -> Void = { _ in }) -> Scenario {
        hud("wordwave-\(name)") { m in
            m.wordWaveform = true
            m.status = HUDStatus.listening
            m.levels = .demo(peak: 0.8)
            m.pulsePhase = 0.25
            let words = demoWords(text, pauseAfter: pauseAfter, stableBefore: stableBefore)
            m.utterance = demoLevels(for: words)
            m.showWords(text: text, words: words)
            configure(m)
        }
    }

    public static var wordWaveScenarios: [Scenario] {
        let short = "Please move the standup to three thirty and let everyone know"
        let long = "Please move the standup to three thirty and let everyone know, then check the rollout plan with the whole team before the release review, and remind the designers about the icon sizes, we still need the dark variants and the notification badge, and finally book the room"
        return [
            wordWave("listening", short, pauseAfter: [4], stableBefore: 6),
            wordWave("listening-start", "so the first", stableBefore: 0),
            wordWave("long", long, pauseAfter: [11, 23, 34], stableBefore: 40),
            wordWave("polishing", rawSentence, pauseAfter: [5]) { $0.beginPolishing(raw: rawSentence, style: "Email", words: nil); $0.shimmerPhase = 0.45 },
            wordWave("revised", short, pauseAfter: [4], stableBefore: 3) { m in
                var words = demoWords(short, pauseAfter: [4], stableBefore: 3)
                words[6].text = "and then"; words[7].text = "let"
                m.showWords(text: words.map(\.text).joined(separator: " "), words: words)
            },
            wordWave("finished", short, pauseAfter: [4]) { m in
                m.finishWords(text: short, words: demoWords(short, pauseAfter: [4]))
                m.status = HUDStatus.inserting
            },
            wordWave("reduce-motion", short, pauseAfter: [4], stableBefore: 6) { $0.reduceMotion = true },
            wordWave("contrast", short, pauseAfter: [4], stableBefore: 6) { $0.increaseContrast = true },
            wordWave("multiline-polishing", long, pauseAfter: [11, 23, 34]) { $0.beginPolishing(raw: long, style: "Notes", words: nil); $0.shimmerPhase = 0.6 },
        ]
    }
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

    /// The Pond Ripple at review size (the HUD glyph is 20 pt): driven at a few levels, plus the
    /// Reduce Motion ring whose stroke follows the level.
    public static var rippleScenarios: [Scenario] {
        func ripple(_ name: String, _ make: @escaping () -> Ripple) -> Scenario {
            Scenario(name: "ripple-\(name)") { NSHostingView(rootView: SnapshotBackdrop { make() }) }
        }
        return [
            ripple("silent") { Ripple(level: 0, phase: 0.15, side: 120) },
            ripple("speech") { Ripple(level: 0.7, phase: 0.4, side: 120) },
            ripple("peak") { Ripple(level: 1, phase: 0.8, side: 120) },
            ripple("static") { Ripple(level: 0.7, reduceMotion: true, side: 120) },
        ]
    }

    public static var hudScenarios: [Scenario] {
        let (stable, tail) = splitPartial(text: sentence + " about the release", stable: sentence)
        let long = Array(repeating: "and then we should also check the rollout plan with the whole team", count: 5).joined(separator: ", ")
        return [
            hud("connecting") { $0.status = HUDStatus.connecting },
            hud("listening") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.8); $0.pulsePhase = 0.4; $0.stable = stable; $0.unstable = tail },
            hud("listening-no-text") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.45); $0.pulsePhase = 0.4 },
            hud("listening-unstable-only") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 1); $0.pulsePhase = 0.4; $0.unstable = "so the first words are" },
            hud("listening-multiline") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.7); $0.pulsePhase = 0.6; $0.stable = long; $0.unstable = " and finally" },
            hud("listening-reduce-motion") { $0.status = HUDStatus.listening; $0.reduceMotion = true; $0.levels = .demo(peak: 0.6); $0.stable = stable; $0.unstable = tail },
            hud("listening-contrast") {
                $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.8); $0.pulsePhase = 0.4; $0.increaseContrast = true
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
            state.inputs = [boya, studio]; state.defaultInput = boya
            state.about = AboutInfo(version: "0.1.0", build: "1")
            configure(&state)
            return Scenario(name: "settings-\(tab.rawValue)-\(name)") {
                let form = SettingsForm(state, icon: appIcon, onNotices: {})
                let view = form.view(for: tab)
                view.setFrameSize(form.fittingSize(for: tab))
                return view
            }
        }
        let styled: (inout SettingsState) -> Void = {
            $0.cleanupEnabled = true
            $0.catalog = StyleCatalog(profiles: samplePrompts, source: .live)
            $0.cleanupDetail = "Runs on this Mac: tidies punctuation and wording before the text is inserted."
            $0.keepLoaded = KeepLoadedState(settings: CleanupModelSettings(keepLoaded: true, loaded: true, model: "qwen3-4b", memoryMB: 2662),
                                            availability: .available)
        }
        /// Settings → Devices with a fixed clock and zone, so the snapshot never changes with the day it is drawn.
        func devicesForm(_ name: String, _ phase: DevicesPhase, revoking: String? = nil, problem: String? = nil) -> Scenario {
            Scenario(name: "settings-devices-\(name)") {
                var state = SettingsState()
                state.about = AboutInfo(version: "0.1.0", build: "1")
                let form = SettingsForm(state, icon: appIcon, onNotices: {})
                form.devicesView.apply(phase, revoking: revoking, problem: problem, now: sampleNow,
                                       locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
                let view = form.view(for: .devices)
                view.setFrameSize(form.fittingSize(for: .devices))
                return view
            }
        }
        let warmOff = CleanupModelSettings(keepLoaded: false, model: "qwen3-4b", memoryMB: 2662, memoryEstimated: true)
        return [
            devicesForm("ready", .loaded(samplePhones)),
            devicesForm("revoking", .loaded(samplePhones), revoking: "9f3a1c52"),
            devicesForm("empty", .loaded([])),
            devicesForm("unavailable", .unavailable(DevicesError.outdated.message)),
            devicesForm("revoke-failed", .loaded(samplePhones), problem: DevicesError.failed.message),
            devicesForm("remote", .remote("studio.example-tailnet.ts.net")),
            form("ready", .general) { _ in },
            form("login-unavailable", .general) { $0.launch = .unavailable },
            form("missing", .general) { $0.micGranted = false; $0.accessibilityGranted = false },
            form("ready", .shortcuts) { _ in },
            form("custom", .shortcuts) {
                $0.hotkey = .custom(keyCode: 0x0F, modifiers: UInt32(controlKey | optionKey | cmdKey))   // ⌃⌥⌘R
                $0.notesHotkey = .custom(keyCode: 0x2E, modifiers: UInt32(controlKey | optionKey))       // ⌃⌥M
            },
            form("fn", .shortcuts) { $0.hotkey = .custom(keyCode: KeyCombo.anyModifierKey, modifiers: ModifierKeys.fn) },
            Scenario(name: "settings-shortcuts-rejected") {
                var state = SettingsState()
                state.inputs = [boya, studio]; state.defaultInput = boya
                let form = SettingsForm(state)
                // As if ⇧ had just been pressed and let go in the recorder, and ⌃⌥Space typed for Live Notes (set
                // directly: no event monitor offscreen).
                form.recorder.apply(.rejected(.shiftAlone))
                form.notesShortcut.refuse(.inUse("dictation"))
                let view = form.view(for: .shortcuts)
                view.setFrameSize(form.fittingSize(for: .shortcuts))
                return view
            },
            form("ready", .dictation) { _ in },
            form("option-hold", .dictation) { $0.hotkey = .option; $0.activationMode = .holdToTalk },
            form("picked-microphone", .dictation) { $0.chosenInputUID = "studio" },
            form("sounds", .dictation) { $0.soundsEnabled = true; $0.soundPack = .chirp; $0.soundVolume = 0.6 },
            form("sounds-custom", .dictation) {
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
            form("downloaded", .notes) { $0.speakerModelDownloaded = true },
            form("not-downloaded", .notes) { _ in },
            form("ready", .server) { styled(&$0) },
            form("unreachable", .server) {
                $0.tokenPresent = false; $0.serverURL = "https://mainframe.example.ts.net/chirp"
                $0.serverStatus = "Unreachable"; $0.serverStatusTone = .error
            },
            form("warm-off", .server) { styled(&$0); $0.keepLoaded = KeepLoadedState(settings: warmOff, availability: .available) },
            form("warm-loading", .server) {
                styled(&$0)
                $0.keepLoaded = KeepLoadedState(settings: CleanupModelSettings(keepLoaded: true, loading: true, model: "qwen3-4b", memoryMB: 2662, memoryEstimated: true),
                                                availability: .available)
            },
            form("warm-remote-host", .server) {
                styled(&$0); $0.serverHost = "mainframe.example.ts.net"; $0.serverURL = "https://mainframe.example.ts.net/chirp"
                $0.keepLoaded = KeepLoadedState(settings: CleanupModelSettings(keepLoaded: true, loaded: true, model: "qwen3-4b", memoryMB: 2662),
                                                availability: .available)
            },
            form("warm-error", .server) {
                styled(&$0)
                $0.keepLoaded = KeepLoadedState(settings: warmOff, availability: .available, error: CleanupSettingsError.unreachable.changeFailure)
            },
            form("warm-old-server", .server) { styled(&$0); $0.keepLoaded = KeepLoadedState(availability: .unavailable(.serverTooOld)) },
            form("warm-remote-model", .server) { styled(&$0); $0.keepLoaded = KeepLoadedState(availability: .unavailable(.remoteModel)) },
            form("ready", .about) { _ in },
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

    /// A made-up link: the snapshots never read the real token.
    static let sampleLink = try! PairingLink(serverURL: TailscaleServe.pairingURL(host: "my-mac.example-tailnet.ts.net"),
                                             token: "snapshot-sample-not-a-real-token-0123456789")

    static let sampleNow = Date(timeIntervalSince1970: 1_792_000_000)   // 2026-10-14 17:46 UTC
    static let samplePhones = [
        PairedDevice(id: "9f3a1c52", name: "Pixel 9", created: sampleNow.addingTimeInterval(-9 * 86_400), lastSeen: sampleNow.addingTimeInterval(-40)),
        PairedDevice(id: "04be77d1", name: "iPad", created: sampleNow.addingTimeInterval(-40 * 86_400), lastSeen: sampleNow.addingTimeInterval(-3 * 3_600)),
        PairedDevice(id: "c81d20aa", name: "Akshay’s phone", created: sampleNow.addingTimeInterval(-3_600)),
    ]

    public static var pairingScenarios: [Scenario] {
        func pairing(_ name: String, _ step: PairingStep, remaining: Int = 107, concealed: Bool = false) -> Scenario {
            Scenario(name: "pairing-\(name)") {
                let view = PairingView()
                view.apply(step, remaining: remaining, concealed: concealed)
                return view
            }
        }
        let command = TailscaleServe.publishCommand(port: 7821)
        return [
            pairing("checking", .checking),
            pairing("naming", .naming(suggested: "Akshay’s phone", problem: nil)),
            pairing("naming-taken", .naming(suggested: "Pixel 9", problem: "A device with that name is already paired; revoke it first")),
            pairing("cannot-mint", .cannotMint(DevicesError.outdated.message)),
            pairing("ready", .ready(sampleLink)),
            pairing("concealed", .ready(sampleLink), concealed: true),
            pairing("not-served", .notServed(command: command)),
            pairing("publish-failed", .publishFailed(command: command, reason: "Serve is not enabled on your tailnet.\nTo enable, visit the Tailscale admin console.")),
            pairing("no-tailscale", .noTailscale),
            pairing("funnel", .funnel),
            pairing("conflict", .conflict("http://127.0.0.1:9000")),
        ]
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
                $0.healthError = "Server unreachable at 127.0.0.1"
            },
            menu("permissions-missing") {
                $0.health = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true)
                $0.micGranted = false; $0.accessibilityGranted = false
            },
            menu("error") {
                $0.state = .error("Microphone access denied — enable it in System Settings")
                $0.health = local; $0.micGranted = false; $0.inputs = []; $0.defaultInput = nil
            },
            menu("notes-recording") {
                $0.health = local; $0.cleanupOn = true
                $0.notesRecording = true; $0.notesElapsed = "12:34"; $0.notesHasDocument = true
            },
            menu("use-raw") { $0.health = local; $0.cleanupOn = true; $0.rawOfferOpen = true; $0.rawOfferKey = "⌃⌥Z" },
            menu("long-names") {
                $0.health = local; $0.chosenInputUID = "long"
                $0.inputs = [boya, AudioInput(uid: "long", name: "Studio Display Microphone (Built-in, Aggregate)")]
            },
            submenu("cleanup-submenu", of: "Clean-up") { $0.health = local; $0.cleanupOn = true; $0.styleID = "email" },
            submenu("cleanup-submenu-off", of: "Clean-up") { $0.health = local },
            submenu("microphone-submenu", of: "Microphone") { $0.health = local; $0.chosenInputUID = "studio" },
        ]
    }

    /// The scenarios whose PNGs are committed under `docs/screenshots/mac`: the key HUD states, the menu in light and
    /// dark, one per Settings tab, and the setup window. The rest only render to a temporary directory for review.
    public static let committedNames: [String] = [
        "hud-listening", "hud-listening-reduce-motion", "ripple-speech", "ripple-static",
        "hud-flow-2-polishing", "hud-flow-3-diff", "hud-correction-use-raw",
        "hud-wordwave-listening", "hud-wordwave-long", "hud-wordwave-polishing",
        "menu-ready", "menu-cleanup-submenu",
        "settings-general-missing", "settings-shortcuts-custom", "settings-dictation-sounds", "settings-cleanup-custom", "settings-notes-downloaded",
        "settings-server-ready", "settings-devices-ready", "settings-about-ready", "onboarding-welcome",
        "notes-editing", "notes-split", "notes-paused", "notes-review-sheet", "notes-tip",
    ]

    public static var committedScenarios: [Scenario] {
        let all = allScenarios
        return committedNames.compactMap { name in all.first { $0.name == name } }
    }

    public static var localModelsScenarios: [Scenario] {
        ["missing", "downloading", "paused", "error", "ready", "stale", "sensevoice"].map { name in
            Scenario(name: "models-" + name) {
                var state = LocalModelsState()
                state.correctionMode = "managed"
                state.correctionEnabled = true
                state.options = [
                    LocalModelOption(id: "v2", kind: .speech, title: "Parakeet TDT v2 · English", repository: "mlx-community/parakeet-tdt-0.6b-v2", revision: "8ae155301e", sizeBytes: 2_472_000_000, details: "English · existing default", license: "cc-by-4.0", ready: name == "ready", active: true, engine: "mlx"),
                    LocalModelOption(id: "v3", kind: .speech, title: "Parakeet TDT v3 · Multilingual", repository: "mlx-community/parakeet-tdt-0.6b-v3", revision: "ed2b7e8c15", sizeBytes: 2_509_000_000, details: "25 languages", engine: "mlx"),
                    LocalModelOption(id: "qwen", kind: .cleanup, title: "Qwen3 4B Instruct · 4-bit", repository: "mlx-community/Qwen3-4B-Instruct-2507-4bit", revision: "50d427756c", sizeBytes: 2_263_000_000, details: "Local text correction", ready: name == "ready", active: true),
                ]
                state.choices = [.speech: "v2", .cleanup: "qwen"]
                state.activeModels = ["speech": "v2", "cleanup": "qwen"]
                state.message = "Choose and download models, then start your local server."
                for model in LocalModel.allCases {
                    state.models[model]?.phase = switch name {
                    case "downloading": "downloading"
                    case "paused": "cancelled"
                    case "error": "error"
                    case "ready": "complete"
                    default: "missing"
                    }
                    state.models[model]?.completed = 850_000_000
                    state.models[model]?.total = 2_470_000_000
                    state.models[model]?.message = "Connection interrupted. Retry to continue."
                }
                if name == "sensevoice" {
                    state.options.append(LocalModelOption(id: "sensevoice-small", kind: .speech, title: "SenseVoice Small · 中文 / 粵語 / English", repository: "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17", revision: "2365baeacb", sizeBytes: 938_576_997, details: "Mandarin, Cantonese, English and mixed speech · CPU · adds a 12 MB runtime on first download", license: "FunASR model license", ready: true, engine: "sensevoice"))
                    state.choices[.speech] = "sensevoice-small"; state.activeModels["speech"] = "sensevoice-small"
                    state.models[.speech]?.phase = "complete"; state.models[.cleanup]?.phase = "complete"
                    state.restartRequired = true
                    state.message = "Selection saved. Apply and restart the server when you’re ready."
                }
                if name == "stale" { state.finish("download", model: .speech, code: 2, sawEvent: false, interrupted: false) }
                if name == "ready" {
                    state.serverRunning = true
                    state.message = "Server running · Ready to dictate"
                }
                let view = LocalModelsView()
                view.apply(state)
                return view
            }
        }
    }

    // MARK: Live Notes

    /// An invented meeting: an agenda the user typed, three structured segments settled, two more in the AI tail,
    /// a live partial.
    static func demoNotes(gap: Bool = false, short: Bool = false, typed: Bool = true) -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 1_792_504_980))
        if typed { d.userEdit(NSRange(location: 0, length: 0), "## Agenda\n- Lantern kickoff\n- Budget check-in\n- [x] Share the doc with Maya\n") }
        let said: [(TimeInterval, String, String)] = [
            (12, "okay so we're kicking off the lantern project today and the launch target moved to march third",
             "Okay, so we're kicking off the Lantern project today, and the launch target moved to March third."),
            (48, "maya will send the draft spec by friday and theo books the design review",
             "Maya will send the draft spec by Friday, and Theo books the design review."),
            (95, "on budget we decided to keep the vendor contract but we will not add new headcount this quarter",
             "On budget, we decided to keep the vendor contract, but we will not add new headcount this quarter."),
        ]
        for (i, s) in said.enumerated() { d.append(NotesSegment(id: i, offset: s.0, raw: s.1, text: s.2, corrected: true)) }
        let first = ["## Project kickoff", "- Launch target moved to **March 3**", "- [ ] Maya to send the draft spec by **Friday**",
                     "- [ ] Theo to book the design review", "", "## Budget", "- **Decision:** keep the vendor contract",
                     "- _No_ new headcount this quarter"].joined(separator: "\n")
        if let r = d.nextStructureRequest() { d.apply(NotesStructureResponse(markdown: first, structured: true), for: r) }
        d.freezeAll()
        if short { return d }
        if gap { d.append(.gap(id: 3, offset: 140, reason: "Server is busy")) }
        d.append(NotesSegment(id: 4, offset: 151, raw: "open question is who owns qa for the beta",
                              text: "open question is who owns qa for the beta", keptOriginal: gap))
        d.append(NotesSegment(id: 5, offset: 176, raw: "the beta itself should start in the second week of april",
                              text: "The beta itself should start in the second week of April.", corrected: true))
        let open = ["## Beta", "- **Question:** who owns QA for the beta?", "- Beta starts in the second week of **April**"]
            .joined(separator: "\n")
        if let r = d.nextStructureRequest() { d.apply(NotesStructureResponse(markdown: open, structured: true), for: r) }
        d.append(NotesSegment(id: 6, offset: 201, raw: "and marketing wants a teaser", text: "And marketing wants a teaser."))
        d.livePartial = "and we still need the onboarding emails for the first"
        return d
    }

    /// The same meeting with speaker labels: three people, a backchannel, a turn across a segment boundary, an
    /// approximate segment (no word timings).
    static func demoSpeakers() -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 1_792_504_980))
        typealias T = SpeakerAttribution.Turn
        let said: [(TimeInterval, String, [T])] = [
            (12, "okay so we're kicking off the lantern project today and the launch target moved to march third yeah march third", [
                T(slot: 2, start: 12, text: "Okay, so we're kicking off the Lantern project today, and the launch target moved to March third.",
                  raw: "okay so we're kicking off the lantern project today and the launch target moved to march third"),
                T(slot: 0, start: 19.4, text: "Yeah, March third.", raw: "yeah march third"),
            ]),
            (48, "maya will send the draft spec by friday and theo books the design review", [
                T(slot: 0, start: 48, text: "Maya will send the draft spec by Friday, and Theo books the design review.",
                  raw: "maya will send the draft spec by friday and theo books the design review"),
            ]),
            (95, "on budget we decided to keep the vendor contract but no new headcount this quarter agreed", [
                T(slot: 3, start: 95, text: "On budget, we decided to keep the vendor contract, but no new headcount this quarter.",
                  raw: "on budget we decided to keep the vendor contract but no new headcount this quarter"),
                T(slot: 2, start: 103.2, text: "Agreed.", raw: "agreed"),
            ]),
            (151, "open question is who owns qa for the beta", [
                T(slot: 0, start: 151, text: "Open question is who owns QA for the beta.", raw: "open question is who owns qa for the beta",
                  approximate: true),
            ]),
        ]
        for (i, s) in said.enumerated() {
            d.append(NotesSegment(id: i, offset: s.0, raw: s.1, text: s.2.map(\.text).joined(separator: " "), corrected: true))
            d.attachSpeakers(s.2, toSegment: i)
        }
        d.livePartial = "the beta itself should start in the second week"
        return d
    }

    /// Forty minutes into a long session: segments that run on without a pause read as one paragraph, sections
    /// remember when they were said, and 1:30 of speech waits for the notes.
    static func demoLong() -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 1_792_504_980))
        let said: [(TimeInterval, String, TimeInterval?)] = [
            (2412, "So the launch target moved to March third, which gives us about six weeks for the beta, and", nil),
            (2457, "most of that goes to the onboarding flow. Maya will send the draft spec by Friday.", 0.3),
            (2502, "Theo books the design review for the week after, once the spec is in.", 0.2),
            (2547, "On budget, we decided to keep the vendor contract, but we will not add new headcount this quarter.", 3.1),
            (2592, "Open question is who owns QA for the beta, and whether", nil),
            (2637, "support should join the first two weeks of it.", 0.4),
        ]
        func add(_ i: Int) {
            var s = NotesSegment(id: i, offset: said[i].0, raw: said[i].1.lowercased(), text: said[i].1, corrected: true)
            s.end = said[i].0 + 45
            s.pauseBefore = said[i].2
            d.append(s)
        }
        for i in 0..<3 { add(i) }
        let first = ["## Launch plan", "- Launch target moved to **March 3**: about six weeks of beta",
                     "- [ ] Maya to send the draft spec by **Friday**", "- [ ] Theo to book the design review"].joined(separator: "\n")
        if let r = d.nextStructureRequest() { d.apply(NotesStructureResponse(markdown: first, structured: true), for: r) }
        d.freezeAll()
        add(3)
        let budget = ["## Budget", "- **Decision:** keep the vendor contract", "- _No_ new headcount this quarter"].joined(separator: "\n")
        if let r = d.nextStructureRequest() { d.apply(NotesStructureResponse(markdown: budget, structured: true), for: r) }
        d.freezeAll()
        for i in 4..<6 { add(i) }
        d.livePartial = "and the onboarding emails for the first"
        return d
    }

    /// The demo after a reorganize: the agenda and the kickoff merged, tasks collected at the end.
    static func reorganizedNotes() -> NotesDocument {
        var d = demoNotes()
        let md = ["## Agenda", "- Lantern kickoff", "- Budget check-in", "", "## Project kickoff", "- Launch target moved to **March 3**",
                  "", "## Budget", "- **Decision:** keep the vendor contract", "- _No_ new headcount this quarter", "",
                  "## Beta", "- Beta starts in the second week of **April**", "- **Question:** who owns QA for the beta?", "",
                  "## Action items", "- [x] Share the doc with Maya", "- [ ] Maya to send the draft spec by **Friday**",
                  "- [ ] Theo to book the design review"].joined(separator: "\n")
        if let r = d.reorganizeRequest(final: false, manual: true) {
            d.applyReorganize(NotesReorganizeResponse(markdown: md, reorganized: true, changed: true), for: r)
        }
        return d
    }

    /// One organize that regrouped the demo notes, as the review sheet and the chip show it.
    static func demoSnapshots() -> NotesSnapshots {
        let before = demoNotes().text
        let after = reorganizedNotes().text
        var snapshots = NotesSnapshots()
        if let change = NotesDocument.diff(before, after, kind: .reorganize) {
            snapshots.record([change], from: before, result: after, at: Date(timeIntervalSince1970: 1_700_000_000))
        }
        return snapshots
    }

    static func notes(_ name: String, width: CGFloat = 820, _ configure: @escaping (NotesModel) -> Void) -> Scenario {
        Scenario(name: "notes-\(name)") {
            let model = NotesModel()
            model.dictationKey = "⌥"
            model.state = .recording
            model.libraryEnabled = true
            model.privacyLine = NotesModel.libraryPrivacy
            model.privacyHelp = NotesModel.libraryPrivacyHelp
            model.document = demoNotes()
            model.elapsed = 192
            model.canManageModels = true
            configure(model)
            // A little under the default window size, so the committed PNGs stay small.
            return NSHostingView(rootView: NotesView(model: model).frame(width: width, height: 560))
        }
    }

    public static var notesScenarios: [Scenario] {
        [
            notes("editing") { $0.structuring = .running },
            notes("preview") { $0.preview = true },
            notes("reorganized") {
                $0.document = reorganizedNotes()
                $0.reorganizeStatus = .applied(at: 1)
            },
            notes("reorganizing") { $0.reorganizeStatus = .running },
            notes("voice-edit-listening") {
                $0.voiceEditAvailable = true
                $0.canVoiceEdit = true
                $0.voiceEdit = .listening(heard: "remove the bit about the budget")
            },
            notes("voice-edited") {
                $0.voiceEditAvailable = true
                $0.canVoiceEdit = true
                $0.voiceEdit = .done(.applied, at: 1)
            },
            notes("voice-edit-refused") {
                $0.state = .stopped
                $0.voiceEditAvailable = true
                $0.canVoiceEdit = true
                $0.voiceEdit = .done(.refused("adds_content"), at: 1)
            },
            notes("organizing") { $0.state = .stopped; $0.reorganizeStatus = .organizing(step: 2, of: 3) },
            notes("organize-partial") {
                $0.state = .stopped
                $0.reorganizeStatus = .organized(failed: 1, reason: "rejected: novel_name")
            },
            notes("split") {
                $0.tab = .split
                var d = demoNotes(short: true)
                d.livePartial = "the beta itself should start in the second"
                $0.document = d
            },
            notes("recovered") {
                $0.state = .stopped; $0.elapsed = 0; $0.document = NotesDocument()
                $0.recovery = RecoveryOffer(startedAt: Date(timeIntervalSince1970: 1_792_504_980), elapsed: 52 * 60)
                $0.privacyLine = NotesStatus.privacyRecovery
            },
            notes("keep-saving-stopped") {
                $0.state = .stopped
                $0.privacyLine = NotesStatus.privacyRecovery
                $0.keepSaving = .stopped(KeepSavingStatus.moved)
            },
            notes("offline") { $0.connection = .offline(kept: 252) },
            notes("catching-up") { $0.connection = .catchingUp(segments: 3) },
            notes("mic-silent") { $0.micNotice = .silent },
            notes("mic-switched") { $0.micNotice = .switched("MacBook Pro Microphone") },
            notes("paused-slept") { $0.state = .paused; $0.pauseReason = NotesStatus.sleptPause },
            notes("transcript-raw") { $0.tab = .transcript; $0.showRaw = true; $0.document = demoNotes(gap: true) },
            notes("transcript") { $0.tab = .transcript; $0.document = demoNotes(gap: true) },
            notes("transcript-speakers") {
                $0.tab = .transcript; $0.document = demoSpeakers(); $0.speakerLabels = true; $0.speakerModel = .ready
            },
            notes("transcript-speakers-renamed") {
                var d = demoSpeakers()
                d.renameSpeaker(2, to: "Maya")
                $0.tab = .transcript; $0.document = d; $0.speakerLabels = true; $0.speakerModel = .ready
                $0.speakerBanner = SpeakerBanner(document: d.id, kind: .offerReplace(old: "Person 2", new: "Maya", count: 2))
            },
            notes("hearing-speakers") {
                var d = demoSpeakers()
                d.userEdit(NSRange(location: 0, length: 0), "## Lantern kickoff\n- Launch target moved to **March 3**\n")
                $0.document = d; $0.speakerLabels = true; $0.speakerModel = .ready
            },
            notes("speakers-downloading") {
                $0.state = .idle; $0.tab = .transcript; $0.speakerModel = .downloading(0.42); $0.elapsed = 0
                $0.document = NotesDocument()
            },
            notes("structuring-off-editable") {
                var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 1_792_504_980))
                d.userEdit(NSRange(location: 0, length: 0), "## My notes\n- Lantern launch moved to **March 3**\n- Ask Theo about the design review\n- [ ] ")
                for s in demoNotes().segments { d.append(s) }
                d.livePartial = "and we still need the onboarding emails"
                $0.document = d
                $0.structuring = .off(.correctionOff)
                $0.reorganizeStatus = .unavailable(.correctionOff)
            },
            notes("structure-failed") {
                $0.structuring = .failed("timeout")
                $0.reorganizeStatus = .failed("rejected")
                $0.structuringHost = "llm.example.com"
                $0.debugRetention = true
            },
            notes("old-server") { $0.reorganizeStatus = .unavailable(.unsupported) },
            notes("stopped") {
                $0.state = .stopped
                var d = demoNotes()
                d.livePartial = ""
                d.freezeAll()
                $0.document = d
            },
            notes("empty") { $0.state = .idle; $0.document = NotesDocument(); $0.elapsed = 0 },
            notes("long-lag") { $0.document = demoLong(); $0.elapsed = 2690 },
            notes("long-transcript") {
                $0.tab = .transcript; $0.document = demoLong(); $0.elapsed = 2690; $0.hoveredParagraph = "0"
            },
            notes("long-preview") { $0.document = demoLong(); $0.elapsed = 2690; $0.preview = true; $0.structuring = .idle },
            notes("long-run") { $0.document = demoLong(); $0.elapsed = 7262 },
            notes("error") { $0.state = .error("Notes stopped: Server rejected the token") },
            notes("paused") { $0.state = .paused; $0.elapsed = 754; var d = demoNotes(); d.livePartial = ""; $0.document = d },
            notes("paused-asleep") { $0.state = .paused; $0.pauseReason = "Paused while the Mac slept"; $0.elapsed = 754 },
            notes("level") { $0.level = 0.8; $0.structuring = .idle },
            notes("min-width", width: NotesViewMetrics.minimumSize.width) {
                $0.structuringHost = "llm.example.com"
                $0.structuring = .running
            },
            notes("structuring-host") { $0.structuringHost = "llm.example.com" },
            notes("reorganized-changes") {
                $0.document = reorganizedNotes()
                $0.reorganizeStatus = .applied(at: 1)
                $0.snapshots = demoSnapshots()
            },
            Scenario(name: "notes-review-sheet") {
                let model = NotesModel()
                model.snapshots = demoSnapshots()
                model.review()
                return NSHostingView(rootView: OrganizeReviewSheet(model: model).background(Color(nsColor: .windowBackgroundColor)))
            },
            Scenario(name: "notes-review-confirm") {
                let model = NotesModel()
                model.snapshots = demoSnapshots()
                model.review()
                model.confirmingRestore = model.reviewing
                return NSHostingView(rootView: OrganizeReviewSheet(model: model).background(Color(nsColor: .windowBackgroundColor)))
            },
            Scenario(name: "notes-tip") {
                NSHostingView(rootView: NotesTipView().background(Color(nsColor: .windowBackgroundColor)))
            },
        ]
    }

    public static var allScenarios: [Scenario] {
        hudScenarios + rippleScenarios + wordWaveScenarios + settingsScenarios + onboardingScenarios + menuScenarios
            + localModelsScenarios + notesScenarios + pairingScenarios
    }

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
        let isWindow = ["settings-", "onboarding-", "models-", "notes-", "pairing-"].contains { scenario.name.hasPrefix($0) }
        host.fillColor = isWindow ? .windowBackgroundColor : .clear
        host.appearance = appearance
        host.contentView = view
        host.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        // An NSTextView inside SwiftUI lays out lazily; make it draw offscreen.
        for textView in textViews(in: host) {
            if let tlm = textView.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
            textView.needsDisplay = true
        }
        view.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        return isWindow ? opaquePNG(rep) ?? rep.representation(using: .png, properties: [:]) : rep.representation(using: .png, properties: [:])
    }

    /// A window is opaque, so its PNG drops the alpha channel: the same pixels in a smaller file. (`cacheDisplay`
    /// only draws into a bitmap with alpha, so the pixels are copied into one that ignores it.)
    private static func opaquePNG(_ rep: NSBitmapImageRep) -> Data? {
        guard let image = rep.cgImage,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = NSMutableData()
        guard let opaque = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, opaque, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
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
