import Foundation
import Carbon.HIToolbox
import Testing
@testable import ChirpCore
@testable import ChirpUI

@Suite struct PreferencesTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "chirp-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func inputDeviceChoicePersistsAndClears() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(Preferences(defaults: defaults).inputDeviceUID == nil)
        Preferences(defaults: defaults).inputDeviceUID = "boya"
        #expect(Preferences(defaults: defaults).inputDeviceUID == "boya")
        Preferences(defaults: defaults).inputDeviceUID = nil
        #expect(Preferences(defaults: defaults).inputDeviceUID == nil)
    }

    @Test func cleanupToggleIsTheWireCorrectionFlag() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.startOptions() == StartOptions(client: "mac", correction: false))
        prefs.correction.toggle()
        #expect(prefs.startOptions() == StartOptions(client: "mac", correction: true))
        #expect(ClientMessage.start(prefs.startOptions()).contains("\"correction\":true"))
    }

    @Test func rawAfterCleanupDefaultsOnAndPersistsOff() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(Preferences(defaults: defaults).showRawAfterCleanup)
        Preferences(defaults: defaults).showRawAfterCleanup = false
        #expect(!Preferences(defaults: defaults).showRawAfterCleanup)
    }

    @Test func existingPreferencesKeepTheirKeysAndDefaults() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.hotkey == .controlOptionSpace && prefs.serverURL == ServerConfig.defaultURL.absoluteString)
        defaults.set("control-shift-space", forKey: "hotkey")
        defaults.set(true, forKey: "correction")
        #expect(prefs.hotkey == .controlShiftSpace && prefs.correction)
    }
}

@Suite struct InputSelectionTests {
    let boya = AudioInput(uid: "boya", name: "BOYA CM40")
    let studio = AudioInput(uid: "studio", name: "Studio Display Microphone")

    @Test func followsTheSystemDefaultUnlessADeviceIsPicked() {
        #expect(InputSelection.resolve(chosen: nil, available: [boya, studio]) == nil)
        #expect(InputSelection.resolve(chosen: "studio", available: [boya, studio]) == studio)
    }

    @Test func aPickedDeviceThatWasUnpluggedFallsBackToTheDefault() {
        #expect(InputSelection.resolve(chosen: "studio", available: [boya]) == nil)
        #expect(InputSelection.resolve(chosen: "studio", available: []) == nil)
    }
}

@Suite struct MenuContentTests {
    private let boya = AudioInput(uid: "boya", name: "BOYA CM40")
    private let studio = AudioInput(uid: "studio", name: "Studio Display Microphone")
    private let local = Health(engine: "parakeet", ready: true, correction: "available", correctionLeavesMachine: false)

    private func inputs(_ configure: (inout MenuInputs) -> Void = { _ in }) -> MenuInputs {
        var m = MenuInputs()
        m.inputs = [boya, studio]
        m.defaultInput = boya
        m.health = local
        configure(&m)
        return m
    }
    private func entry(_ m: MenuInputs, _ action: MenuAction) -> MenuEntry? {
        MenuContent.entries(m).first { $0.action == action }
    }
    private func titles(_ m: MenuInputs) -> [String] { MenuContent.entries(m).filter { !$0.isSeparator && !$0.isHeader }.map(\.title) }

    // MARK: header and status

    @Test func headerNamesTheAppWithTheHotkeyHint() {
        let header = MenuContent.entries(inputs())[0]
        #expect(header.title == "Chirp" && header.showsAppIcon)
        #expect(header.subtitle == "⌃⌥Space — tap to toggle, hold to talk")
        #expect(MenuContent.entries(inputs { $0.hotkey = .controlShiftSpace })[0].subtitle?.hasPrefix("⌃⇧Space") == true)
    }

    @Test func statusLineCoversEveryState() {
        func status(_ configure: (inout MenuInputs) -> Void) -> (String, MenuEntry.Tone) {
            let e = MenuContent.status(inputs(configure))
            return (e.title, e.tone)
        }
        #expect(status { _ in } == ("Ready", .ok))
        #expect(status { $0.health = Health(ready: false) } == ("Loading model…", .warning))
        #expect(status { $0.health = nil; $0.healthError = "x" } == ("Server unreachable", .error))
        #expect(status { $0.health = nil } == ("Checking server…", .warning))
        #expect(status { $0.state = .listening } == ("Listening", .active))
        #expect(status { $0.state = .connecting } == ("Connecting…", .active))
        #expect(status { $0.state = .error("boom") } == ("boom", .error))
        // What Chirp is doing wins over the server's state.
        #expect(status { $0.state = .listening; $0.health = nil; $0.healthError = "x" } == ("Listening", .active))
    }

    @Test func debugRetentionIsAlwaysVisibleInRed() {
        #expect(MenuContent.entries(inputs()).allSatisfy { !$0.title.hasPrefix("DEBUG") })
        let line = MenuContent.entries(inputs { $0.debugRetention = true }).first { $0.title.hasPrefix("DEBUG") }
        #expect(line?.tone == .error && line?.title == "DEBUG retention ON — recordings kept")
    }

    // MARK: dictation

    @Test func startDictationTurnsIntoStopAndCarriesNoKeyEquivalent() {
        let idle = entry(inputs(), .toggleDictation)
        // The header shows the hotkey once; a ⌃⌥Space equivalent would render in odd columns.
        #expect(idle?.title == "Start dictation" && idle?.keyEquivalent == nil)
        #expect(entry(inputs { $0.state = .listening }, .toggleDictation)?.title == "Stop dictation")
        #expect(entry(inputs { $0.state = .error("x") }, .toggleDictation)?.title == "Start dictation")
        // Nothing to start or stop while the final is on its way.
        #expect(entry(inputs { $0.state = .finalizing }, .toggleDictation) == nil)
        #expect(entry(inputs { $0.state = .inserting }, .toggleDictation) == nil)
    }

    // MARK: input device

    @Test func inputPickerListsEveryDeviceAndMarksTheEffectiveOne() throws {
        let following = try #require(MenuContent.entries(inputs()).first { $0.title == "Input Device" })
        #expect(following.subtitle == "BOYA CM40")
        let sub = try #require(following.submenu).filter { !$0.isSeparator }
        #expect(sub.map(\.title) == ["System Default", "BOYA CM40", "Studio Display Microphone"])
        #expect(sub.map(\.mark) == [.on, .off, .off])
        #expect(sub.map(\.action) == [.pickInput(nil), .pickInput("boya"), .pickInput("studio")])
        #expect(sub[0].subtitle == "BOYA CM40")

        let picked = try #require(MenuContent.entries(inputs { $0.chosenInputUID = "studio" }).first { $0.title == "Input Device" })
        #expect(picked.subtitle == "Studio Display Microphone")
        #expect(try #require(picked.submenu).filter { $0.mark == .on }.map(\.title) == ["Studio Display Microphone"])
    }

    @Test func unpluggedPickedDeviceFallsBackToTheDefaultAndSaysSo() throws {
        let e = try #require(MenuContent.entries(inputs { $0.inputs = [boya]; $0.chosenInputUID = "studio" }).first { $0.title == "Input Device" })
        #expect(e.subtitle == "BOYA CM40 (picked device not connected)")
        #expect(try #require(e.submenu).filter { $0.mark == .on }.map(\.title) == ["System Default"])
    }

    @Test func noInputDeviceIsFlaggedAndHasNoPicker() throws {
        let e = try #require(MenuContent.entries(inputs { $0.inputs = []; $0.defaultInput = nil }).first { $0.title == "Input Device" })
        #expect(e.subtitle == "No input device" && e.tone == .warning && e.submenu == nil)
    }

    // MARK: clean-up

    @Test func cleanupToggleReflectsThePreference() {
        #expect(entry(inputs(), .toggleCleanup)?.mark == .off)
        #expect(entry(inputs { $0.cleanupOn = true }, .toggleCleanup)?.mark == .on)
    }

    @Test func cleanupSaysWhereTheTextGoes() {
        func subtitle(_ h: Health?) -> String? { entry(inputs { $0.health = h }, .toggleCleanup)?.subtitle }
        #expect(subtitle(local) == "Runs on this Mac")
        #expect(subtitle(Health(correction: "available", correctionLeavesMachine: true, correctionHost: "llm.example.com"))
                == "Sends text to llm.example.com")
        #expect(subtitle(Health(correction: "available", correctionLeavesMachine: true)) == "Sends text to a remote LLM")
        // Shown before turning it on, not only after.
        #expect(entry(inputs { $0.cleanupOn = false; $0.health = Health(correction: "available", correctionLeavesMachine: true, correctionHost: "h") },
                      .toggleCleanup)?.subtitle == "Sends text to h")
    }

    @Test func serverWithoutCleanupGetsOneExplanatoryRowAndNoGreyedCheckedItems() throws {
        for on in [true, false] {
            let m = inputs { $0.health = Health(engine: "p", ready: true, correction: "off"); $0.cleanupOn = on; $0.showRawAfterCleanup = true }
            #expect(entry(m, .toggleCleanup) == nil && entry(m, .toggleShowRaw) == nil)
            let all = MenuContent.entries(m)
            let section = try #require(all.firstIndex { $0.isHeader && $0.title == "Clean-up" })
            let row = all[section + 1]
            #expect(row.title == "Clean-up: off on server — see README" && row.action == nil && row.mark == .off)
            #expect(all[section + 2].isSeparator)
            #expect(!all.contains { $0.title == "Clean up text" || $0.title == "Show raw after clean-up" })
        }
    }

    @Test func noMenuItemIsCheckedWhileDisabled() {
        let configs: [(inout MenuInputs) -> Void] = [
            { _ in }, { $0.cleanupOn = true }, { $0.cleanupOn = true; $0.showRawAfterCleanup = false },
            { $0.health = Health(correction: "off"); $0.cleanupOn = true }, { $0.health = nil; $0.cleanupOn = true },
            { $0.launch = .unavailable }, { $0.launch = .on },
        ]
        for configure in configs {
            for e in MenuContent.entries(inputs(configure)) where e.mark != .off {
                #expect(e.action != nil, "\(e.title) is checked but has no action")
            }
        }
    }

    @Test func showRawOptionNeedsCleanupOn() {
        #expect(entry(inputs { $0.cleanupOn = false }, .toggleShowRaw) == nil)
        #expect(entry(inputs { $0.cleanupOn = true }, .toggleShowRaw)?.mark == .on)
        #expect(entry(inputs { $0.cleanupOn = true; $0.showRawAfterCleanup = false }, .toggleShowRaw)?.mark == .off)
    }

    @Test func unreachableServerStillLetsYouSetTheCleanupPreference() {
        let m = inputs { $0.health = nil; $0.healthError = "x" }
        #expect(entry(m, .toggleCleanup)?.subtitle == "Server unreachable")
    }

    // MARK: hotkey, server, permissions, footer

    @Test func hotkeySubmenuMarksTheCurrentPreset() throws {
        let hotkey = try #require(MenuContent.entries(inputs()).first { $0.title == "Hotkey" })
        #expect(hotkey.subtitle == "⌃⌥Space")
        let sub = try #require(hotkey.submenu)
        #expect(sub.prefix(KeyCombo.presets.count).map(\.title) == KeyCombo.presets.map(\.title))
        #expect(sub.filter { $0.mark == .on }.map(\.action) == [.pickHotkey("control-option-space")])
        // Recording happens in Settings; the menu only points there.
        #expect(sub.last?.action == .showSettings)
    }

    @Test func aCustomHotkeyIsListedAndChecked() throws {
        let custom = KeyCombo.custom(keyCode: 0x0F, modifiers: UInt32(controlKey | optionKey | cmdKey))
        let hotkey = try #require(MenuContent.entries(inputs { $0.hotkey = custom }).first { $0.title == "Hotkey" })
        #expect(hotkey.subtitle == "⌃⌥⌘R")
        let sub = try #require(hotkey.submenu)
        #expect(sub.filter { $0.mark == .on }.map(\.title) == ["⌃⌥⌘R (custom)"])
    }

    @Test func soundsAndSetupHaveRows() {
        #expect(entry(inputs(), .toggleSounds)?.mark == .off)
        #expect(entry(inputs { $0.soundsEnabled = true }, .toggleSounds)?.mark == .on)
        #expect(entry(inputs(), .showSetup)?.title == "Set Up Chirp…")
        #expect(MenuAction.showSetup.payload == nil)
    }

    @Test func serverRowShowsTheURLWithAStatusDot() throws {
        func row(_ configure: (inout MenuInputs) -> Void) throws -> MenuEntry {
            try #require(MenuContent.entries(inputs(configure)).first { $0.action == .showSettings && $0.symbol == "circle.fill" })
        }
        let ok = try row { $0.serverURL = "https://mainframe.example.ts.net/chirp" }
        #expect(ok.title == "https://mainframe.example.ts.net/chirp" && ok.symbolTone == .ok && ok.subtitle == "parakeet")
        #expect(try row { $0.health = nil; $0.healthError = "x" }.symbolTone == .error)
        #expect(try row { $0.health = Health(ready: false) }.symbolTone == .warning)
        #expect(entry(inputs(), .copyDoctor)?.title == "Open doctor output")
    }

    @Test func permissionsAppearOnlyWhenSomethingIsMissing() {
        #expect(!MenuContent.entries(inputs()).contains { $0.isHeader && $0.title.hasPrefix("Permissions") })
        #expect(entry(inputs(), .grantMic) == nil && entry(inputs(), .grantAX) == nil)

        let mic = inputs { $0.micGranted = false }
        #expect(entry(mic, .grantMic) != nil && entry(mic, .grantAX) == nil)
        #expect(MenuContent.entries(mic).contains { $0.isHeader && $0.title == "Permissions needed" })

        let ax = inputs { $0.accessibilityGranted = false }
        #expect(entry(ax, .grantMic) == nil && entry(ax, .grantAX) != nil)
    }

    @Test func footerHasLaunchSettingsAboutAndQuit() {
        let t = titles(inputs())
        #expect(t.suffix(5) == ["Launch at Login", "Set Up Chirp…", "Settings…", "About Chirp", "Quit Chirp"])
        #expect(entry(inputs(), .quit)?.keyEquivalent == "q" && MenuContent.entries(inputs()).first { $0.title == "Settings…" }?.keyEquivalent == ",")
        #expect(entry(inputs(), .showAbout) != nil)
    }

    @Test func launchAtLoginIsAPlainCheckboxWithTheErrorUnderneath() {
        var m = inputs()
        func item() -> MenuEntry { MenuContent.entries(m).first { $0.title == "Launch at Login" }! }
        #expect(item().mark == .off && item().action == .toggleLaunch && item().subtitle == nil)
        m.launch = .on
        #expect(item().mark == .on && item().action == .toggleLaunch)
        m.launchError = "Operation not permitted"
        #expect(item().subtitle == "Couldn’t change it: Operation not permitted" && item().symbolTone == .error)
        m.launch = .unavailable
        #expect(item().action == nil && item().mark == .off)
    }

    @Test func headerBlockIsTheFirstRowFollowedByTheStatusLines() {
        let all = MenuContent.entries(inputs { $0.debugRetention = true })
        let firstSeparator = all.firstIndex { $0.isSeparator }!
        #expect(all[0].showsAppIcon && all[1].title == "Ready" && all[2].title.hasPrefix("DEBUG") && firstSeparator == 3)
        #expect(all.dropFirst().allSatisfy { !$0.showsAppIcon })
    }

    @Test func itemPayloadsCarryTheirChoice() {
        #expect(MenuAction.pickInput("boya").payload == "boya" && MenuAction.pickInput(nil).payload == nil)
        #expect(MenuAction.pickHotkey("control-shift-space").payload == "control-shift-space")
        #expect(MenuAction.quit.payload == nil)
    }
}

@Suite struct StatusIconTests {
    private func icon(_ state: DictationState, reachable: Bool = true, debug: Bool = false, reduceMotion: Bool = false) -> StatusIcon {
        StatusIcon.of(state: state, serverReachable: reachable, debugRetention: debug, reduceMotion: reduceMotion)
    }

    @Test func glyphFollowsTheDictationState() {
        #expect(icon(.idle).glyph == .idle)
        for s in [DictationState.connecting, .listening, .finalizing, .inserting] { #expect(icon(s).glyph == .listening) }
        #expect(icon(.error("x")).glyph == .error)
    }

    @Test func dimmedOnlyWhileIdleAndTheServerIsUnreachable() {
        #expect(icon(.idle, reachable: false).dimmed)
        #expect(!icon(.idle).dimmed)
        #expect(!icon(.listening, reachable: false).dimmed)
        #expect(!icon(.error("x"), reachable: false).dimmed)
    }

    @Test func debugBadgeFollowsRetention() {
        #expect(icon(.idle, debug: true).debugBadge && !icon(.idle).debugBadge)
        #expect(icon(.listening, debug: true).debugBadge)
        #expect(icon(.idle, debug: true).accessibilityLabel == "Chirp, debug recordings kept")
    }

    @Test func wavesPulseOnlyWhileListeningAndNeverWithReduceMotion() {
        #expect(icon(.listening).animatesWaves && icon(.connecting).animatesWaves)
        #expect(!icon(.idle).animatesWaves && !icon(.error("x")).animatesWaves)
        #expect(!icon(.listening, reduceMotion: true).animatesWaves)
        #expect(StatusIcon.waveAlpha(phase: 0, reduceMotion: false) == 1)
        #expect(StatusIcon.waveAlpha(phase: 1, reduceMotion: false) < 0.5)
        #expect(StatusIcon.waveAlpha(phase: 2, reduceMotion: false) == 1)
        #expect((0..<6).allSatisfy { StatusIcon.waveAlpha(phase: $0, reduceMotion: true) == 1 })
    }

    @Test func accessibilityLabelSaysWhatIsWrong() {
        #expect(icon(.idle).accessibilityLabel == "Chirp")
        #expect(icon(.idle, reachable: false).accessibilityLabel == "Chirp — server unreachable")
        #expect(icon(.listening).accessibilityLabel == "Chirp — dictating")
    }
}

@Suite struct DoctorHelpTests {
    @Test func clipboardTextHasTheCommandsAndNoSecrets() {
        let text = DoctorHelp.clipboardText(serverURL: "http://127.0.0.1:7821")
        #expect(text.contains("uv run chirp-server doctor --quick") && text.contains("uv run chirp-server doctor "))
        #expect(text.contains("http://127.0.0.1:7821"))
        #expect(!text.lowercased().contains("token"))
    }
}
