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
    private let local = Health(engine: "parakeet", ready: true, correction: "available", correctionLeavesMachine: false,
                               correctionProfiles: CorrectionProfile.builtIn)

    private func inputs(_ configure: (inout MenuInputs) -> Void = { _ in }) -> MenuInputs {
        var m = MenuInputs()
        m.inputs = [boya, studio]
        m.defaultInput = boya
        m.health = local
        configure(&m)
        return m
    }
    private func entry(_ m: MenuInputs, _ title: String) -> MenuEntry? { MenuContent.entries(m).first { $0.title == title } }
    private func entry(_ m: MenuInputs, _ action: MenuAction) -> MenuEntry? { MenuContent.entries(m).first { $0.action == action } }
    private func titles(_ m: MenuInputs) -> [String] { MenuContent.entries(m).filter { !$0.isSeparator }.map(\.title) }
    /// The rows with their separators, as one string per group.
    private func groups(_ m: MenuInputs) -> [[String]] {
        var out: [[String]] = [[]]
        for e in MenuContent.entries(m) {
            if e.isSeparator { if !out[out.count - 1].isEmpty { out.append([]) } } else { out[out.count - 1].append(e.title) }
        }
        return out
    }

    // MARK: the structure

    @Test func readyMenuHasTheTargetStructure() {
        #expect(groups(inputs()) == [["Start Dictation"], ["Clean-up", "Microphone", "Sounds", "Server"],
                                     ["Settings…", "About Chirp"], ["Quit Chirp"]])
        #expect(MenuContent.header(inputs()).title == "Chirp")
    }

    @Test func rowsAreSingleLineWithoutIconsOrSectionHeaders() {
        // MenuEntry has no subtitle, symbol or header kind any more: a row is a title plus a value or shortcut.
        for e in MenuContent.entries(inputs()) where !e.isSeparator {
            #expect(!e.title.isEmpty && !e.title.contains("\n"))
            #expect(e.value == nil || e.shortcut == nil)
        }
        // Under the header, around the dictation rows, around Settings/About and above Quit.
        #expect(MenuContent.entries(inputs()).filter(\.isSeparator).count == 4)
    }

    @Test func hotkeyAndLaunchAtLoginLiveOnlyInSettings() {
        let all = MenuContent.entries(inputs { $0.cleanupOn = true }).flatMap { [$0] + ($0.submenu ?? []) }
        #expect(!all.contains { $0.title == "Hotkey" || $0.title == "Launch at Login" })
    }

    // MARK: header and status

    @Test func headerStatusCoversEveryState() {
        func status(_ configure: (inout MenuInputs) -> Void) -> (String, MenuEntry.Tone) {
            let h = MenuContent.header(inputs(configure))
            return (h.status, h.tone)
        }
        #expect(status { _ in } == ("Ready · ⌃⌥Space", .normal))
        #expect(status { $0.hotkey = .controlShiftSpace } == ("Ready · ⌃⇧Space", .normal))
        #expect(status { $0.paused = true } == ("Paused", .normal))
        #expect(status { $0.state = .listening } == ("Listening…", .active))
        #expect(status { $0.state = .connecting } == ("Connecting…", .active))
        #expect(status { $0.state = .correcting } == ("Polishing…", .active))
        #expect(status { $0.state = .error("boom") } == ("boom", .error))
        #expect(status { $0.health = nil; $0.healthError = "x" } == ("Server unreachable", .error))
        #expect(status { $0.health = nil } == ("Checking server…", .warning))
        #expect(status { $0.health = Health(ready: false) } == ("Loading model…", .warning))
        #expect(status { $0.debugRetention = true } == ("DEBUG recordings kept", .error))
        #expect(status { $0.hotkeyRegistered = false }.1 == .warning)
        // What Chirp is doing wins over the server's state; the pause wins over everything.
        #expect(status { $0.state = .listening; $0.health = nil; $0.healthError = "x" } == ("Listening…", .active))
        #expect(status { $0.paused = true; $0.debugRetention = true } == ("Paused", .normal))
    }

    @Test func theSwitchIsOnExactlyWhileRunning() {
        #expect(MenuContent.header(inputs()).isOn)
        #expect(!MenuContent.header(inputs { $0.paused = true }).isOn)
    }

    @Test func headerReadsAsOneLabelForVoiceOver() {
        #expect(MenuContent.header(inputs()).accessibilityLabel == "Chirp, Ready · ⌃⌥Space")
        #expect(MenuContent.header(inputs { $0.paused = true }).accessibilityLabel == "Chirp, Paused")
    }

    // MARK: dictation rows

    @Test func startDictationShowsTheHotkeyAndTurnsIntoStop() {
        let idle = entry(inputs(), .toggleDictation)
        #expect(idle?.title == "Start Dictation" && idle?.shortcut == "⌃⌥Space" && idle?.keyEquivalent == nil)
        #expect(entry(inputs { $0.hotkey = .controlShiftSpace }, .toggleDictation)?.shortcut == "⌃⇧Space")
        #expect(entry(inputs { $0.state = .listening }, .toggleDictation)?.title == "Stop Dictation")
        #expect(entry(inputs { $0.state = .error("x") }, .toggleDictation)?.title == "Start Dictation")
        // Nothing to start or stop while the final is on its way.
        #expect(entry(inputs { $0.state = .finalizing }, .toggleDictation) == nil)
        #expect(entry(inputs { $0.state = .inserting }, .toggleDictation) == nil)
    }

    @Test func pausedMenuCannotStartADictationAndShowsNoShortcut() throws {
        let row = try #require(entry(inputs { $0.paused = true }, "Start Dictation"))
        #expect(row.action == nil && row.shortcut == nil && !row.isEnabled)
        // A shortcut another app owns is not advertised either.
        #expect(try #require(entry(inputs { $0.hotkeyRegistered = false }, "Start Dictation")).shortcut == nil)
    }

    @Test func useRawAppearsOnlyDuringItsWindowWithItsShortcut() throws {
        #expect(entry(inputs(), .useRaw) == nil)
        let open = try #require(entry(inputs { $0.rawOfferOpen = true; $0.rawOfferKey = "⌃⌥Z" }, .useRaw))
        #expect(open.title == "Use Raw for Last Dictation" && open.shortcut == "⌃⌥Z")
        #expect(try #require(entry(inputs { $0.rawOfferOpen = true }, .useRaw)).shortcut == nil)
        #expect(groups(inputs { $0.rawOfferOpen = true })[0] == ["Start Dictation", "Use Raw for Last Dictation"])
    }

    // MARK: Clean-up

    @Test func cleanupValueIsTheDefaultStyleOrOff() throws {
        #expect(try #require(entry(inputs(), "Clean-up")).value == "Off")
        #expect(try #require(entry(inputs { $0.cleanupOn = true }, "Clean-up")).value == "Default")
        #expect(try #require(entry(inputs { $0.cleanupOn = true; $0.styleID = "email" }, "Clean-up")).value == "Email")
        // Unreachable: the style's built-in name, still shown.
        #expect(try #require(entry(inputs { $0.health = nil; $0.healthError = "x"; $0.cleanupOn = true; $0.styleID = "chat" }, "Clean-up")).value == "Chat")
    }

    @Test func cleanupSubmenuHasToggleStylesShowChangesAndEditStyles() throws {
        let row = try #require(entry(inputs { $0.cleanupOn = true; $0.styleID = "email"; $0.showChanges = true }, "Clean-up"))
        let sub = try #require(row.submenu)
        #expect(sub.filter { !$0.isSeparator }.map(\.title) == ["Clean up Text", "Default", "Chat", "Email", "Code", "Notes", "Custom",
                                                                "Show Changes after Clean-up", "Edit Styles…"])
        #expect(sub.first?.action == .toggleCleanup && sub.first?.mark == .on)
        #expect(sub.filter { $0.mark == .on }.map(\.title) == ["Clean up Text", "Email", "Show Changes after Clean-up"])
        #expect(sub.first { $0.title == "Chat" }?.action == .pickStyle("chat"))
        #expect(sub.first { $0.title == "Show Changes after Clean-up" }?.action == .toggleShowChanges)
        #expect(sub.last?.action == .editStyles)
    }

    @Test func cleanupSubmenuMarksNothingWhenOff() throws {
        let sub = try #require(entry(inputs(), "Clean-up")?.submenu)
        #expect(sub.first?.mark == .off && sub.first { $0.title == "Show Changes after Clean-up" }?.mark == .off)
        #expect(sub.first { $0.title == "Default" }?.mark == .on)   // the default style is still the one a later toggle uses
    }

    @Test func serverWithoutCleanupExplainsInsteadOfOfferingAToggle() throws {
        for on in [true, false] {
            let m = inputs { $0.health = Health(engine: "p", ready: true, correction: "off"); $0.cleanupOn = on }
            let row = try #require(entry(m, "Clean-up"))
            #expect(row.value == "Unavailable")
            let sub = try #require(row.submenu)
            #expect(sub.first?.title == "Clean-up is off on the server" && sub.first?.action == nil)
            #expect(!sub.contains { $0.action == .toggleCleanup })
            #expect(sub.last?.action == .editStyles)
        }
    }

    @Test func aServerThatListsNoStylesGetsNoStyleRows() throws {
        // An older server ignores styles, so there is nothing to pick; the toggle and Edit Styles… remain.
        let sub = try #require(entry(inputs { $0.health = Health(engine: "p", ready: true, correction: "available") }, "Clean-up")?.submenu)
        #expect(sub.filter { !$0.isSeparator }.map(\.title) == ["Clean up Text", "Show Changes after Clean-up", "Edit Styles…"])
        // Before the first health check the built-in styles are offered, so the menu is not empty while it loads.
        let loading = try #require(entry(inputs { $0.health = nil }, "Clean-up")?.submenu)
        #expect(loading.contains { $0.action == .pickStyle("default") })
    }

    @Test func noMenuItemIsCheckedWhileDisabled() {
        let configs: [(inout MenuInputs) -> Void] = [
            { _ in }, { $0.cleanupOn = true }, { $0.cleanupOn = true; $0.showChanges = true },
            { $0.health = Health(correction: "off"); $0.cleanupOn = true }, { $0.health = nil; $0.cleanupOn = true },
            { $0.soundsEnabled = true }, { $0.chosenInputUID = "studio" }, { $0.paused = true },
        ]
        for configure in configs {
            for top in MenuContent.entries(inputs(configure)) {
                for e in [top] + (top.submenu ?? []) where e.mark != .off {
                    #expect(e.action != nil, "\(e.title) is checked but has no action")
                }
            }
        }
    }

    // MARK: Microphone

    @Test func microphoneSubmenuListsEveryDeviceAndMarksTheEffectiveOne() throws {
        let following = try #require(entry(inputs(), "Microphone"))
        #expect(following.value == "BOYA CM40")
        let sub = try #require(following.submenu).filter { !$0.isSeparator }
        #expect(sub.map(\.title) == ["Follow System Default", "BOYA CM40", "Studio Display Microphone"])
        #expect(sub.map(\.mark) == [.on, .off, .off])
        #expect(sub.map(\.action) == [.pickInput(nil), .pickInput("boya"), .pickInput("studio")])

        let picked = try #require(entry(inputs { $0.chosenInputUID = "studio" }, "Microphone"))
        #expect(picked.value?.hasPrefix("Studio Display") == true && picked.value?.hasSuffix("…") == true)
        #expect(picked.fullValue == "Studio Display Microphone")
        #expect(try #require(picked.submenu).filter { $0.mark == .on }.map(\.title) == ["Studio Display Microphone"])
    }

    @Test func unpluggedPickedDeviceFallsBackToTheDefault() throws {
        let e = try #require(entry(inputs { $0.inputs = [boya]; $0.chosenInputUID = "studio" }, "Microphone"))
        #expect(e.value == "BOYA CM40")
        #expect(try #require(e.submenu).filter { $0.mark == .on }.map(\.title) == ["Follow System Default"])
    }

    @Test func noInputDeviceIsFlaggedAndHasNoPicker() throws {
        let e = try #require(entry(inputs { $0.inputs = []; $0.defaultInput = nil }, "Microphone"))
        #expect(e.value == "None" && e.tone == .warning && e.submenu == nil && !e.isEnabled)
    }

    // MARK: values truncate gracefully

    @Test func longValuesEndInAnEllipsisAndKeepTheirFullTextForVoiceOver() throws {
        let long = AudioInput(uid: "long", name: "Studio Display Microphone (Built-in, Aggregate)")
        let row = try #require(entry(inputs { $0.inputs = [long]; $0.chosenInputUID = "long" }, "Microphone"))
        let value = try #require(row.value)
        #expect(value.count <= MenuContent.valueLimit && value.hasSuffix("…") && value.hasPrefix("Studio Display"))
        #expect(row.fullValue == "Studio Display Microphone (Built-in, Aggregate)")
        #expect(row.accessibilityLabel == "Microphone, Studio Display Microphone (Built-in, Aggregate)")
        // The submenu keeps the whole name.
        #expect(row.submenu?.contains { $0.title == long.name } == true)
    }

    @Test func shortValuesAreUntouchedAndTruncationNeverCutsAGrapheme() {
        #expect(MenuContent.truncated("BOYA CM40") == "BOYA CM40")
        #expect(MenuContent.truncated(String(repeating: "a", count: MenuContent.valueLimit)) == String(repeating: "a", count: MenuContent.valueLimit))
        let emoji = MenuContent.truncated(String(repeating: "🎙️", count: 40))
        #expect(emoji.count == MenuContent.valueLimit && emoji.hasSuffix("…"))
        #expect(MenuContent.truncated("ab ", limit: 3) == "ab ")
        #expect(MenuContent.truncated("ab cdefg", limit: 4) == "ab…")   // no dangling space before the ellipsis
    }

    @Test func rowsKeepOnlyTheirTitleWhenThereIsNoValue() {
        let about = entry(inputs(), "About Chirp")
        #expect(about?.accessibilityLabel == "About Chirp")
        #expect(entry(inputs(), "Settings…")?.accessibilityLabel == "Settings…, ⌘,")
        #expect(entry(inputs(), "Start Dictation")?.accessibilityLabel == "Start Dictation, ⌃⌥Space")
    }

    // MARK: Sounds

    @Test func soundsValueIsTheChoiceAndTheSubmenuMarksIt() throws {
        let off = try #require(entry(inputs(), "Sounds"))
        #expect(off.value == "Off" && off.action == nil && off.isEnabled)
        #expect(off.submenu?.filter { $0.mark == .on }.map(\.title) == ["Off"])
        let chirp = try #require(entry(inputs { $0.soundsEnabled = true }, "Sounds"))
        #expect(chirp.value == "Chirp" && chirp.submenu?.filter { $0.mark == .on }.map(\.title) == ["Chirp"])
        #expect(try #require(entry(inputs { $0.soundsEnabled = true; $0.soundPack = .glass }, "Sounds")).value == "Glass")
        #expect(try #require(entry(inputs { $0.soundsEnabled = true; $0.soundPack = .custom }, "Sounds")).value == "Custom")
    }

    // MARK: Server

    @Test func serverValueSaysWhereItRuns() throws {
        #expect(try #require(entry(inputs(), "Server")).value == "This Mac")
        #expect(try #require(entry(inputs { $0.serverURL = "http://localhost:7821" }, "Server")).value == "This Mac")
        #expect(try #require(entry(inputs { $0.serverURL = "https://mainframe.ts.net/chirp" }, "Server")).value == "mainframe.ts.net")
        let far = try #require(entry(inputs { $0.serverURL = "https://mainframe-with-a-very-long-name.example.ts.net/chirp" }, "Server"))
        #expect(far.value?.hasSuffix("…") == true && far.fullValue == "mainframe-with-a-very-long-name.example.ts.net")
    }

    @Test func serverSubmenuShowsUrlEngineStatusAndTheDoctorCommand() throws {
        let sub = try #require(entry(inputs(), "Server")?.submenu)
        #expect(sub.filter { !$0.isSeparator }.map(\.title) == ["http://127.0.0.1:7821", "Engine: parakeet", "Status: Ready", "Copy Doctor Command"])
        #expect(sub.filter { !$0.isSeparator }.map(\.action) == [nil, nil, nil, .copyDoctor])
        let down = try #require(entry(inputs { $0.health = nil; $0.healthError = "x" }, "Server"))
        #expect(down.tone == .error && down.submenu?.map(\.title).contains("Status: Unreachable") == true)
        #expect(entry(inputs { $0.health = Health(ready: false) }, "Server")?.submenu?.map(\.title).contains("Status: Loading model…") == true)
    }

    // MARK: Set Up Chirp…, footer

    @Test func setUpChirpAppearsOnlyWhileSetupIsIncomplete() {
        #expect(entry(inputs(), .showSetup) == nil)
        #expect(entry(inputs { $0.micGranted = false }, .showSetup)?.title == "Set Up Chirp…")
        #expect(entry(inputs { $0.accessibilityGranted = false }, .showSetup) != nil)
        #expect(entry(inputs { $0.health = nil; $0.healthError = "x" }, .showSetup) != nil)
        // Still checking the server is not a reason to nag.
        #expect(entry(inputs { $0.health = nil }, .showSetup) == nil)
        #expect(MenuAction.showSetup.payload == nil)
    }

    @Test func setUpChirpSitsBetweenTheSeparatorAndSettings() {
        let m = inputs { $0.micGranted = false }
        #expect(groups(m)[2] == ["Set Up Chirp…", "Settings…", "About Chirp"])
    }

    @Test func footerHasSettingsAboutAndQuitWithTheirKeys() {
        let settings = entry(inputs(), .showSettings)
        #expect(settings?.keyEquivalent == "," && settings?.shortcut == "⌘,")
        #expect(entry(inputs(), .quit)?.keyEquivalent == "q" && entry(inputs(), .quit)?.shortcut == "⌘Q")
        #expect(entry(inputs(), .showAbout) != nil)
        #expect(titles(inputs()).suffix(3) == ["Settings…", "About Chirp", "Quit Chirp"])
    }

    @Test func permissionsHaveNoRowsInTheMenu() {
        let m = inputs { $0.micGranted = false; $0.accessibilityGranted = false }
        #expect(!titles(m).contains { $0.contains("Allow") || $0.contains("Permission") })
    }

    // MARK: every state

    @Test func everyStateBuildsACoherentMenu() throws {
        let states: [(String, (inout MenuInputs) -> Void)] = [
            ("paused", { $0.paused = true; $0.hotkeyRegistered = false }),
            ("ready", { _ in }),
            ("listening", { $0.state = .listening }),
            ("unreachable", { $0.health = nil; $0.healthError = "x" }),
            ("debug", { $0.debugRetention = true }),
            ("use-raw", { $0.rawOfferOpen = true; $0.rawOfferKey = "⌃⌥Z" }),
            ("setup", { $0.micGranted = false; $0.accessibilityGranted = false }),
        ]
        for (name, configure) in states {
            let m = inputs(configure)
            let all = MenuContent.entries(m)
            // Every group has rows, none is empty or doubled up.
            #expect(zip(all, all.dropFirst()).allSatisfy { !($0.isSeparator && $1.isSeparator) }, "\(name): doubled separator")
            #expect(all.last?.isSeparator == false, "\(name): trailing separator")
            for e in all where !e.isSeparator { #expect(!e.title.isEmpty && (e.value ?? "").count <= MenuContent.valueLimit, "\(name): \(e.title)") }
            #expect(all.filter { $0.title == "Quit Chirp" }.count == 1)
        }
    }

    @Test func itemPayloadsCarryTheirChoice() {
        #expect(MenuAction.pickInput("boya").payload == "boya" && MenuAction.pickInput(nil).payload == nil)
        #expect(MenuAction.pickStyle("email").payload == "email" && MenuAction.pickSound("glass").payload == "glass")
        #expect(MenuAction.quit.payload == nil && MenuAction.editStyles.payload == nil)
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

    @Test func pausedDimsTheIdleBirdAndSaysSo() {
        let paused = StatusIcon.of(state: .idle, serverReachable: true, debugRetention: false, paused: true)
        #expect(paused.glyph == .idle && paused.dimmed && paused.paused && !paused.animatesWaves)
        #expect(paused.accessibilityLabel == "Chirp — paused")
        #expect(!icon(.idle).paused && !icon(.idle).dimmed)
        // A debug badge still shows: the server keeps recordings whether or not Chirp is paused.
        #expect(StatusIcon.of(state: .idle, serverReachable: true, debugRetention: true, paused: true).debugBadge)
        // Paused wins over a leftover dictation state: the bird never pulses.
        #expect(!StatusIcon.of(state: .listening, serverReachable: true, debugRetention: false, paused: true).animatesWaves)
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
        #expect(text.contains("chirp-server doctor --quick") && text.contains("chirp-server doctor\n"))
        #expect(text.contains("http://127.0.0.1:7821"))
        #expect(!text.lowercased().contains("token"))
    }

    @Test(arguments: ["installed", "checkout", "server"])
    func copiedDiagnosticsRunWithoutEditingPaths(location: String) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("Chirp help \(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let bin = root.appendingPathComponent(location == "installed" ? "bin" : "server/.venv/bin")
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("chirp-server")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CHIRP_TEST_CALLS\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let calls = root.appendingPathComponent("calls")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", DoctorHelp.clipboardText(serverURL: "http://127.0.0.1:7821")]
        process.currentDirectoryURL = location == "server" ? root.appendingPathComponent("server") : root
        process.environment = [
            "PATH": location == "installed" ? "\(bin.path):/usr/bin:/bin" : "/usr/bin:/bin",
            "CHIRP_TEST_CALLS": calls.path,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: calls, encoding: .utf8) == "doctor --quick\ndoctor\n")
    }
}

@MainActor
@Suite struct PauseGateTests {
    /// A gate over a fake hotkey: counts registrations and says whether the shortcut is currently held.
    @MainActor private final class Fake {
        var registered = false
        var registerCalls = 0
        var unregisterCalls = 0
        var changes = 0
        var shortcutTaken = false
        lazy var gate = PauseGate(
            register: { [unowned self] in
                registerCalls += 1
                guard !shortcutTaken else { return false }
                registered = true
                return true
            },
            unregister: { [unowned self] in unregisterCalls += 1; registered = false },
            onChange: { [unowned self] in changes += 1 })
    }

    @Test func pauseUnregistersTheHotkeyAndResumeRegistersItAgain() {
        let fake = Fake()
        #expect(fake.gate.registerHotkey() && fake.registered && fake.gate.hotkeyRegistered && !fake.gate.isPaused)
        fake.gate.pause()
        #expect(!fake.registered && fake.gate.isPaused && !fake.gate.hotkeyRegistered)
        #expect(fake.gate.resume() && fake.registered && fake.gate.hotkeyRegistered && !fake.gate.isPaused)
    }

    @Test func nothingBringsTheHotkeyBackWhilePaused() {
        let fake = Fake()
        fake.gate.registerHotkey()
        fake.gate.pause()
        let calls = fake.registerCalls
        // The shortcut recorder stopping, a new shortcut and the app start all call registerHotkey().
        #expect(!fake.gate.registerHotkey() && !fake.registered)
        fake.gate.suspendHotkey()
        #expect(!fake.gate.registerHotkey() && !fake.registered && fake.registerCalls == calls)
    }

    @Test func pausingTwiceAndResumingTwiceAreHarmless() {
        let fake = Fake()
        fake.gate.registerHotkey()
        fake.gate.pause(); fake.gate.pause()
        #expect(fake.unregisterCalls == 1)
        fake.gate.resume()
        let calls = fake.registerCalls
        fake.gate.resume()
        #expect(fake.registerCalls == calls && fake.registered)
    }

    @Test func theSwitchMapsOnToRunning() {
        let fake = Fake()
        fake.gate.registerHotkey()
        fake.gate.setRunning(false)
        #expect(fake.gate.isPaused && !fake.registered)
        fake.gate.setRunning(true)
        #expect(!fake.gate.isPaused && fake.registered)
    }

    @Test func resumeReportsAShortcutAnotherAppOwns() {
        let fake = Fake()
        fake.gate.registerHotkey()
        fake.gate.pause()
        fake.shortcutTaken = true
        #expect(!fake.gate.resume())
        #expect(!fake.gate.isPaused && !fake.gate.hotkeyRegistered)
    }

    @Test func recorderSuspendsAndRestoresWhenRunning() {
        let fake = Fake()
        fake.gate.registerHotkey()
        fake.gate.suspendHotkey()
        #expect(!fake.registered && !fake.gate.hotkeyRegistered)
        #expect(fake.gate.registerHotkey() && fake.registered)
    }

    @Test func everyChangeIsAnnouncedSoTheIconFollows() {
        let fake = Fake()
        fake.gate.registerHotkey()
        let before = fake.changes
        fake.gate.pause()
        fake.gate.resume()
        #expect(fake.changes >= before + 2)
    }

    @Test func statusLineFollowsTheGate() {
        let fake = Fake()
        fake.gate.registerHotkey()
        func inputs() -> MenuInputs {
            var m = MenuInputs()
            m.health = Health(engine: "p", ready: true)
            m.paused = fake.gate.isPaused
            m.hotkeyRegistered = fake.gate.hotkeyRegistered
            return m
        }
        #expect(MenuContent.header(inputs()).status == "Ready · ⌃⌥Space" && MenuContent.header(inputs()).isOn)
        fake.gate.pause()
        #expect(MenuContent.header(inputs()).status == "Paused" && !MenuContent.header(inputs()).isOn)
        fake.gate.resume()
        #expect(MenuContent.header(inputs()).status == "Ready · ⌃⌥Space")
    }
}
