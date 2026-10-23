import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

@Suite struct OutcomePresentationTests {
    @Test func eachOutcomeHasItsWording() {
        let plain = FinalResult(text: "hello")
        #expect(OutcomePresentation.of(.inserted(.ax), final: plain) == .init(status: "Inserted", linger: 1.2))
        #expect(OutcomePresentation.of(.inserted(.paste), final: plain).status == "Inserted")
        #expect(OutcomePresentation.of(.copied, final: plain) == .init(status: "Copied — ⌘V", indicator: .clipboard, linger: 3))
        #expect(OutcomePresentation.of(.insertedUnverified, final: plain).status == "Inserted? ⌘V if empty")
        let secure = OutcomePresentation.of(.refusedSecure, final: plain)
        #expect(secure.isError && secure.status == "Secure field — not inserted" && secure.indicator == .warning)
    }

    @Test func aCleanedInsertionFadesTheHUDAtOnceAndOffersRawElsewhere() {
        let corrected = FinalResult(text: "Hello.", raw: "hello", corrected: true)
        let unchanged = FinalResult(text: "hello", raw: "hello", corrected: true)
        let p = OutcomePresentation.of(.inserted(.ax), final: corrected)
        #expect(p.linger == 0 && !p.showUseRaw && p.offersRawOutsideHUD && p.cleaned)
        let none = OutcomePresentation.of(.inserted(.ax), final: unchanged)
        #expect(!none.showUseRaw && !none.offersRawOutsideHUD)
        #expect(!OutcomePresentation.of(.copied, final: corrected).showUseRaw)
        #expect(!OutcomePresentation.of(.copied, final: corrected).offersRawOutsideHUD)
        #expect(!OutcomePresentation.of(.inserted(.ax), final: corrected, offerRaw: false).offersRawOutsideHUD)
    }

    @Test func showChangesRestoresTheOverlayWithItsUseRawButton() {
        let corrected = FinalResult(text: "Hello.", raw: "hello", corrected: true)
        let on = OutcomePresentation.of(.inserted(.ax), final: corrected, showChanges: true)
        #expect(on.cleaned && on.showUseRaw && on.linger == 5 && !on.offersRawOutsideHUD)
        let off = OutcomePresentation.of(.inserted(.ax), final: corrected, offerRaw: false, showChanges: true)
        #expect(off.cleaned && !off.showUseRaw && off.linger == 1.8)
        #expect(!OutcomePresentation.of(.inserted(.ax), final: FinalResult(text: "hello")).cleaned)
        #expect(!OutcomePresentation.of(.refusedSecure, final: corrected).cleaned)
    }

    @Test func theKeptOriginalNoteIsBrief() {
        let kept = FinalResult(text: "hello", corrected: false, correctionError: "timeout")
        #expect(OutcomePresentation.of(.inserted(.ax), final: kept).linger <= 1)
        #expect(OutcomePresentation.of(.inserted(.ax), final: kept, showChanges: true).linger <= 1)
        #expect(OutcomePresentation.of(.inserted(.ax), final: kept).keptOriginal)
    }
}

@Suite struct HUDTextTests {
    @Test func shortTextIsUntouched() {
        let r = HUDText.tail(stable: "hello ", unstable: "world")
        #expect(r.stable == "hello " && r.unstable == "world")
    }

    @Test func longTextKeepsTheNewestWordsAtAWordBoundary() {
        let words = (1...80).map { "w\($0)" }.joined(separator: " ")
        let r = HUDText.tail(stable: words + " ", unstable: "last")
        let shown = r.stable + r.unstable
        #expect(shown.hasPrefix("…w"))
        #expect(shown.hasSuffix(" w80 last"))
        #expect(shown.count <= 200 + 1)
        #expect(!shown.dropFirst().hasPrefix("w") || shown.dropFirst().first == "w")
        #expect(r.unstable == "last")
    }

    @Test func cutInsideTheUnstableTailKeepsOnlyUnstable() {
        let unstable = (1...60).map { "word\($0)" }.joined(separator: " ")
        let r = HUDText.tail(stable: "old ", unstable: unstable)
        #expect(r.stable.isEmpty)
        #expect(r.unstable.hasPrefix("…word"))
        #expect(r.unstable.hasSuffix("word60"))
    }

    @Test func aSingleLongTokenIsStillCut() {
        let r = HUDText.tail(stable: "", unstable: String(repeating: "x", count: 500))
        #expect(r.unstable.count == 201 || r.unstable.count == 200)
        #expect(r.unstable.hasPrefix("x") || r.unstable.hasPrefix("…"))
    }
}

@Suite struct HUDColorsTests {
    private func luminance(_ c: HUDColors.RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    private func contrast(_ a: HUDColors.RGB, _ b: HUDColors.RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    // The material composited over a mid-tone desktop, measured from the light and dark snapshots.
    private let lightMaterial: HUDColors.RGB = (0.78, 0.80, 0.85)
    private let darkMaterial: HUDColors.RGB = (0.27, 0.29, 0.35)
    // The flat stand-ins used for Increase Contrast and the snapshots.
    @Test func textIsReadableOnTheFlatSurfaces() {
        #expect(contrast(HUDColors.errorLight, HUDColors.surfaceLight) >= 4.5)
        #expect(contrast(HUDColors.errorDark, HUDColors.surfaceDark) >= 4.5)
        #expect(contrast(HUDColors.actionLight, HUDColors.surfaceLight) >= 4.5)
        #expect(contrast(HUDColors.actionDark, HUDColors.surfaceDark) >= 4.5)
    }

    @Test func errorTextMeetsWCAGAANormalText() {
        #expect(contrast(HUDColors.errorLight, lightMaterial) >= 4.5)
        #expect(contrast(HUDColors.errorDark, darkMaterial) >= 4.5)
    }

    @Test func useRawButtonMeetsWCAGAA() {
        #expect(contrast(HUDColors.actionLight, lightMaterial) >= 4.5)
        #expect(contrast(HUDColors.actionDark, darkMaterial) >= 4.5)
    }

    @Test func debugBadgeKeepsWhiteTextReadable() {
        #expect(contrast((1, 1, 1), HUDColors.badgeRGB) >= 4.5)
    }
}

@MainActor
@Suite struct SettingsFormTests {
    @Test func appliesPermissionAndTokenState() {
        var s = SettingsState()
        s.micGranted = false; s.tokenPresent = false; s.launch = .unavailable
        let form = SettingsForm(s)
        #expect(!form.micButton.isHidden && form.accessibilityButton.isHidden)
        #expect(!form.launch.isEnabled && form.launch.state == .off)
        #expect(form.serverURL.stringValue == ServerConfig.defaultURL.absoluteString)
    }

    @Test func fixButtonsShowOnlyForWhatIsMissing() {
        var s = SettingsState()
        let form = SettingsForm(s)
        #expect(form.micButton.isHidden && form.accessibilityButton.isHidden)
        s.accessibilityGranted = false
        form.apply(s)
        #expect(form.micButton.isHidden && !form.accessibilityButton.isHidden)
        #expect(form.micButton.accessibilityLabel() == "Fix Microphone access" && form.accessibilityButton.accessibilityLabel() == "Fix Accessibility access")
    }

    @Test func launchCheckboxShowsTheRealState() {
        var s = SettingsState()
        s.launch = .on
        let form = SettingsForm(s)
        #expect(form.launch.state == .on && form.launch.isEnabled && !form.launch.allowsMixedState)
        s.launch = .off
        form.apply(s, full: true)
        #expect(form.launch.state == .off)
    }

    @Test func periodicRefreshNeverOverwritesTypingOrTheLoginItemError() {
        let form = SettingsForm(SettingsState())
        form.serverURL.stringValue = "http://typing"
        form.setLaunchError("Operation not permitted")
        var s = SettingsState()
        s.micGranted = false; s.serverURL = "http://other"
        form.apply(s)
        #expect(form.serverURL.stringValue == "http://typing")
        #expect(form.launchHelp.stringValue == "Couldn’t change it: Operation not permitted")
        #expect(!form.micButton.isHidden)
        form.apply(s, full: true)
        #expect(form.serverURL.stringValue == "http://other")
        #expect(form.launchHelp.textColor == .secondaryLabelColor)
    }

    // MARK: tabs

    @Test func hasSevenTabsInTheTargetOrder() {
        #expect(SettingsTab.allCases.map(\.title) == ["General", "Dictation", "Clean-up", "Notes", "Server", "Devices", "About"])
        #expect(SettingsTab.allCases.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil })
    }

    @Test func eachControlLivesOnItsOwnTab() {
        let form = SettingsForm(SettingsState())
        func has(_ control: NSView, _ tab: SettingsTab) -> Bool { control.isDescendant(of: form.view(for: tab)) }
        #expect(has(form.launch, .general) && has(form.setupButton, .general) && has(form.micButton, .general) && has(form.accessibilityButton, .general))
        #expect(has(form.hotkey, .dictation) && has(form.recorder, .dictation) && has(form.mode, .dictation) && has(form.silence, .dictation))
        #expect(has(form.microphone, .dictation) && has(form.wordWaveform, .dictation) && has(form.autoEnter, .dictation))
        #expect(has(form.sounds, .dictation) && has(form.soundPack, .dictation) && has(form.volume, .dictation) && has(form.chooseStart, .dictation))
        #expect(has(form.cleanupEnabled, .cleanup) && has(form.style, .cleanup) && has(form.prompts.view, .cleanup))
        #expect(has(form.appStyles.view, .cleanup) && has(form.showChanges, .cleanup) && has(form.insertRawFirst, .cleanup))
        #expect(has(form.removeSpeakerModel, .notes) && has(form.notesButton, .notes) && has(form.notesRecoveryCopy, .notes))
        #expect(has(form.serverURL, .server) && has(form.doctorButton, .server) && has(form.modelsButton, .server) && has(form.keepLoaded, .server))
        #expect(has(form.pairButton, .devices) && has(form.devicesView, .devices) && has(form.rotateButton, .devices) && has(form.about, .about))
        // and on no other
        for control in [form.launch, form.hotkey, form.sounds, form.cleanupEnabled, form.removeSpeakerModel, form.notesRecoveryCopy, form.serverURL, form.keepLoaded,
                        form.pairButton, form.devicesView, form.rotateButton, form.micButton, form.about] {
            #expect(SettingsTab.allCases.filter { has(control, $0) }.count == 1)
        }
    }

    @Test func cleanupTabCarriesEveryCleanupOption() {
        var s = SettingsState()
        s.cleanupEnabled = true; s.showChanges = true; s.offerRaw = false
        let form = SettingsForm(s)
        #expect(form.cleanupEnabled.state == .on && form.showChanges.state == .on && form.offerRaw.state == .off)
        s.cleanupAvailable = false; s.cleanupDetail = "The server has clean-up turned off; see the README to enable it."
        form.apply(s)
        #expect(!form.cleanupEnabled.isEnabled)
    }

    @Test func cleanupDetailSaysWhereTheTextGoes() {
        #expect(SettingsForm.cleanupDetail(health: Health(correction: "available", correctionLeavesMachine: false)).text.hasPrefix("Runs on this Mac"))
        #expect(SettingsForm.cleanupDetail(health: Health(correction: "available", correctionLeavesMachine: true, correctionHost: "llm.example.com")).text
                == "Sends the text to llm.example.com to tidy it.")
        let off = SettingsForm.cleanupDetail(health: Health(correction: "off"))
        #expect(!off.available && off.text.contains("turned off"))
        #expect(SettingsForm.cleanupDetail(health: nil).available)
    }

    @Test func everyTabSharesOneWidthAndIsAsTallAsItsContent() {
        let form = SettingsForm(SettingsState())
        let sizes = SettingsTab.allCases.map { form.fittingSize(for: $0) }
        // One width, so the window never jumps sideways and the seven toolbar tabs always fit.
        #expect(Set(sizes.map(\.width)).count == 1 && sizes[0].width >= SettingsForm.minimumWidth && sizes[0].width < 560)
        #expect(SettingsTab.allCases.allSatisfy { form.view(for: $0).fittingSize.width == sizes[0].width })
        // Not one tall form: only Clean-up (the prompt editor) is tall.
        let heights = Dictionary(uniqueKeysWithValues: zip(SettingsTab.allCases, sizes.map(\.height)))
        #expect(heights[.general]! < 260 && heights[.devices]! < 260 && heights[.notes]! < 360 && heights[.server]! < 380, "\(heights)")
        #expect(heights[.dictation]! < 560, "\(heights)")
        #expect(heights[.cleanup]! > heights[.dictation]! * 1.25)
    }

    @Test func contentIsCentredWithItsMargin() {
        let form = SettingsForm(SettingsState())
        let widest = SettingsTab.allCases.max { form.view(for: $0).subviews[0].fittingSize.width < form.view(for: $1).subviews[0].fittingSize.width }!
        for tab in SettingsTab.allCases {
            let view = form.view(for: tab)
            let size = form.fittingSize(for: tab)
            let body = view.subviews[0]
            view.setFrameSize(size)
            view.layoutSubtreeIfNeeded()
            #expect(body.frame.minX >= 19.5 && abs(body.frame.minY - 20) < 0.5 && abs(size.height - body.frame.maxY - 20) < 0.5, "\(tab.title)")
            // Centred to the point: an odd leftover width rounds half a point to one side.
            #expect(abs(body.frame.midX - size.width / 2) <= 0.5, "\(tab.title)")
            if tab == widest { #expect(abs(body.frame.minX - 20) < 0.5 && abs(size.width - body.frame.maxX - 20) < 0.5) }
        }
    }

    @Test func groupsStartWithExtraSpace() throws {
        let form = SettingsForm(SettingsState())
        let grid = try #require(form.view(for: .dictation).subviews[0] as? NSGridView)
        #expect(grid.row(at: 4).topPadding == SettingsForm.groupSpacing && grid.row(at: 7).topPadding == SettingsForm.groupSpacing)
        #expect(grid.row(at: 2).topPadding == 0)
    }

    @Test func microphonePickerFollowsTheMenuRules() {
        let boya = AudioInput(uid: "boya", name: "BOYA CM40"), studio = AudioInput(uid: "studio", name: "Studio")
        var s = SettingsState()
        s.inputs = [boya, studio, AudioInput(uid: "studio2", name: "Studio")]; s.defaultInput = boya
        let form = SettingsForm(s)
        #expect(form.microphone.itemArray.filter { !$0.isSeparatorItem }.map(\.title) == ["Follow System Default (BOYA CM40)", "BOYA CM40", "Studio", "Studio"])
        #expect(form.microphone.indexOfSelectedItem == 0)
        s.chosenInputUID = "studio2"
        form.apply(s)
        #expect(form.microphone.selectedItem?.representedObject as? String == "studio2")
        // Unplugged: shows the default, as the menu does.
        s.inputs = [boya]
        form.apply(s)
        #expect(form.microphone.indexOfSelectedItem == 0 && form.microphone.numberOfItems == 3)
        s.inputs = []; s.defaultInput = nil
        form.apply(s)
        #expect(!form.microphone.isEnabled)
    }

    @Test func speakerModelShowsItsStateAndRemoveOnlyWhileDownloaded() {
        var s = SettingsState()
        let form = SettingsForm(s)
        #expect(form.removeSpeakerModel.isHidden)
        s.speakerModelDownloaded = true
        form.apply(s)
        #expect(!form.removeSpeakerModel.isHidden && form.removeSpeakerModel.accessibilityLabel() == "Remove the speaker model")
    }

    @Test(arguments: [(SettingsTab.general, SoundPack.chirp, 4), (.dictation, .chirp, 9), (.dictation, .custom, 11), (.cleanup, .chirp, 7),
                      (.notes, .chirp, 5), (.server, .chirp, 6), (.devices, .chirp, 3)])
    func labelsShareARightEdgeAndControlsALeftEdge(tab: SettingsTab, pack: SoundPack, expectedLabels: Int) throws {
        var state = SettingsState()
        state.soundPack = pack
        let form = SettingsForm(state)
        let view = form.view(for: tab)
        view.setFrameSize(form.fittingSize(for: tab))
        view.layoutSubtreeIfNeeded()
        func labels(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? labels(in: $0) }
        }
        let rowLabels = labels(in: view).filter { $0.stringValue.hasSuffix(":") && $0.alignment == .right && !$0.isHidden }
        #expect(rowLabels.count == expectedLabels)
        let edges = rowLabels.map { view.convert($0.bounds, from: $0).maxX }
        #expect(edges.allSatisfy { abs($0 - edges[0]) < 0.5 })
        let leading: [NSView] = switch tab {
        case .general: [form.launch, form.openNotes.alwaysInDock, form.setupButton]
        case .dictation: [form.hotkey, form.mode, form.silence, form.microphone, form.wordWaveform, form.autoEnter, form.sounds, form.soundPack, form.volume]
        case .cleanup: [form.cleanupEnabled, form.style, form.insertRawFirst, form.appStyles.scroll, form.showChanges, form.offerRaw]
        case .notes: [form.notesRecoveryCopy, form.notesButton, form.openNotes.shortcutView]
        case .server: [form.serverURL, form.keepLoaded, form.doctorButton, form.modelsButton]
        case .devices: [form.pairButton, form.devicesView, form.rotateButton]
        case .about: []
        }
        let controlEdges = leading.map { view.convert($0.bounds, from: $0).minX }
        #expect(controlEdges.allSatisfy { abs($0 - controlEdges[0]) < 0.5 && $0 > edges[0] })
    }

    @Test func helpTextUsesTheSecondaryLabelColour() {
        let form = SettingsForm(SettingsState())
        #expect(form.launchHelp.textColor == .secondaryLabelColor)
        #expect(form.launchHelp.font?.pointSize == NSFont.smallSystemFontSize)
    }

    @Test func theToolbarTabControllerHasEveryTabSizedToFit() throws {
        let form = SettingsForm(SettingsState())
        let controller = SettingsTabs.makeController(form: form)
        #expect(controller.tabStyle == .toolbar)
        #expect(controller.tabViewItems.map(\.label) == SettingsTab.allCases.map(\.title))
        #expect(controller.tabViewItems.allSatisfy { $0.image != nil })
        for (item, tab) in zip(controller.tabViewItems, SettingsTab.allCases) {
            let vc = try #require(item.viewController as? SettingsTabController)
            _ = vc.view
            #expect(vc.tab == tab)
            let fit = form.fittingSize(for: tab)
            // Within the screen: its natural size (a little wider only when it has to scroll).
            #expect(vc.preferredContentSize.width >= fit.width && vc.preferredContentSize.height <= fit.height + 0.5)
            #expect(vc.preferredContentSize.height == min(fit.height, SettingsTabController.heightLimit()) || vc.preferredContentSize.height == fit.height)
        }
    }

    @Test func aWindowAroundTheTabsOpensWithoutAFocusedOrSelectedField() throws {
        let form = SettingsForm(SettingsState())
        let controller = SettingsTabs.makeController(form: form)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        #expect(!(window.firstResponder is NSText))
        #expect(window.contentViewController === controller && window.contentView?.frame.width ?? 0 > 300)
        controller.selectedTabViewItemIndex = SettingsTab.server.hashValue == 0 ? 0 : SettingsTab.allCases.firstIndex(of: .server)!
        let current = try #require(controller.tabViewItems[controller.selectedTabViewItemIndex].viewController?.view)
        window.makeFirstResponder(current)
        #expect(!(window.firstResponder is NSText) && form.serverURL.currentEditor() == nil)
    }

    @Test func customSoundRowsChangeOnlyTheDictationTab() throws {
        let form = SettingsForm(SettingsState())
        let controller = SettingsTabs.makeController(form: form)
        let sounds = try #require(controller.tabViewItems[SettingsTab.allCases.firstIndex(of: .dictation)!].viewController as? SettingsTabController)
        _ = sounds.view
        let before = sounds.preferredContentSize.height
        form.showPack(.custom)
        sounds.refreshSize()
        let custom = sounds.preferredContentSize.height
        #expect(custom > before)
        form.showPack(.chirp)
        sounds.refreshSize()
        #expect(sounds.preferredContentSize.height == before, "\(before) → \(custom) → \(sounds.preferredContentSize.height)")
    }
}

// MARK: menu views

@MainActor
@Suite struct MenuViewTests {
    private func row(_ title: String, value: String? = nil, shortcut: String? = nil, submenu: Bool = false,
                     action: MenuAction? = .showSettings) -> MenuRowView {
        MenuRowView(entry: MenuEntry(title: title, value: value, shortcut: shortcut, action: action,
                                     submenu: submenu ? [MenuEntry(title: "x", action: .showSettings)] : nil))
    }

    @Test func rowsAreTwentyFourPointsHighAndAtLeastTheMenuMinimumWide() {
        let r = row("Clean-up", value: "Default", submenu: true)
        #expect(r.frame.height == MenuMetrics.rowHeight && r.frame.width >= MenuMetrics.minimumWidth)
        #expect(r.intrinsicContentSize.height == 24)
    }

    @Test func aRowNeedsRoomForItsTitleItsWholeValueAndTheChevron() {
        let plain = row("Settings…")
        let value = row("Microphone", value: "BOYA CM40", submenu: true)
        let long = row("Microphone", value: "Studio Display Microphone (Built-in…", submenu: true)
        #expect(value.fittingWidth >= plain.fittingWidth)
        #expect(long.fittingWidth > value.fittingWidth)
        #expect(value.fittingWidth >= MenuMetrics.minimumWidth)
    }

    @Test func rowsAreMenuItemsForVoiceOverWithTheFullLabel() {
        let r = MenuRowView(entry: MenuEntry(title: "Microphone", value: "Studio Display Micro…", fullValue: "Studio Display Microphone (USB)",
                                             submenu: [MenuEntry(title: "x", action: .showSettings)]))
        #expect(r.isAccessibilityElement() && r.accessibilityRole() == .menuItem)
        #expect(r.accessibilityLabel() == "Microphone, Studio Display Microphone (USB)")
        #expect(r.accessibilityHelp() == "Opens a submenu")
        let disabled = row("Start Dictation", shortcut: "⌃⌥Space", action: nil)
        #expect(!disabled.isAccessibilityEnabled() && disabled.accessibilityLabel() == "Start Dictation, ⌃⌥Space")
    }

    @Test func headerShowsTheSwitchAndAnnouncesItsChanges() {
        var seen: [Bool] = []
        let on = MenuHeaderView(header: MenuContent.header(MenuInputs()))
        on.onToggle = { seen.append($0) }
        #expect(on.toggle.state == .on && on.frame.height == MenuHeaderView.height)
        on.toggle.state = .off
        on.toggle.performClick(nil)   // flips it back on and sends the action
        #expect(seen.count == 1)
        var paused = MenuInputs()
        paused.paused = true
        #expect(MenuHeaderView(header: MenuContent.header(paused)).toggle.state == .off)
    }

    @Test func headerIsOneGroupForVoiceOverAndTheSwitchIsLabelled() {
        let view = MenuHeaderView(header: MenuContent.header(MenuInputs()))
        #expect(view.accessibilityLabel() == "Chirp, Checking server…")
        #expect(view.toggle.accessibilityLabel() == "Chirp")
        #expect(view.toggle.accessibilityHelp()?.contains("Turns dictation on or off") == true)
    }
}

@MainActor
@Suite struct SnapshotTests {
    private func render() throws -> (URL, [URL]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-snap-\(UUID().uuidString)")
        return (dir, try Snapshots.render(to: dir))
    }

    @Test func rendersEveryStateInLightAndDarkAsNonBlankPNGs() throws {
        let (dir, files) = try render()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(files.count == Snapshots.allScenarios.count * 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == files.count)
        let names = Set(files.map(\.lastPathComponent))
        for state in ["listening", "listening-multiline", "listening-contrast", "listening-reduce-motion", "finalizing", "inserted", "copied", "unverified-ax", "secure-field",
                      "no-mic-signal", "debug-badge", "correction-use-raw", "cleaned-no-raw-button"] {
            #expect(names.contains("hud-\(state)-light.png") && names.contains("hud-\(state)-dark.png"))
        }
        #expect(names.contains("settings-general-ready-dark.png") && names.contains("menu-ready-light.png") && names.contains("menu-microphone-submenu-dark.png"))
        for tab in SettingsTab.allCases { #expect(names.contains { $0.hasPrefix("settings-\(tab.rawValue)-") }, "no snapshot for the \(tab.title) tab") }
        for state in ["paused", "listening", "unreachable", "debug", "use-raw", "permissions-missing", "long-names"] {
            #expect(names.contains("menu-\(state)-light.png") && names.contains("menu-\(state)-dark.png"))
        }
        for name in ["onboarding-welcome", "onboarding-try-it-success", "onboarding-microphone-blocked", "settings-about-ready", "settings-dictation-custom-hotkey"] {
            #expect(names.contains("\(name)-light.png") && names.contains("\(name)-dark.png"))
        }
        for url in files {
            let data = try Data(contentsOf: url)
            #expect(data.count < 250_000, "\(url.lastPathComponent) is too big to commit")
            let rep = try #require(NSBitmapImageRep(data: data))
            #expect(rep.pixelsWide > 100 && rep.pixelsHigh > 50)
            // Not a flat fill: some pixel differs from the corner.
            let corner = rep.colorAt(x: 0, y: 0)
            var differs = false
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) where !differs {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 7) where rep.colorAt(x: x, y: y) != corner { differs = true; break }
            }
            #expect(differs, "\(url.lastPathComponent) is blank")
        }
    }

    @Test func lightAndDarkAreDifferentImages() throws {
        let (dir, _) = try render()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["hud-listening", "settings-general-ready", "menu-ready"] {
            let light = try Data(contentsOf: dir.appendingPathComponent("\(name)-light.png"))
            let dark = try Data(contentsOf: dir.appendingPathComponent("\(name)-dark.png"))
            #expect(light != dark)
        }
    }

    @Test func multilineHUDIsTallerThanASingleLineOne() throws {
        let (dir, _) = try render()
        defer { try? FileManager.default.removeItem(at: dir) }
        func height(_ n: String) throws -> Int {
            try #require(NSBitmapImageRep(data: Data(contentsOf: dir.appendingPathComponent(n)))).pixelsHigh
        }
        #expect(try height("hud-listening-multiline-light.png") > height("hud-listening-no-text-light.png"))
        // The HUD never grows beyond its 4-line cap, however much is dictated.
        #expect(try height("hud-listening-multiline-light.png") < 400)
    }

    @Test func theCommittedSetIsCuratedAndSmall() throws {
        let names = Snapshots.committedNames
        let all = Set(Snapshots.allScenarios.map(\.name))
        #expect(names.allSatisfy { all.contains($0) } && Set(names).count == names.count)
        #expect(names.count * 2 <= 44)
        // The menu in light and dark, one per Settings tab, setup, the key HUD states and the Notes window.
        #expect(names.contains("notes-editing") && names.contains("notes-split"))
        #expect(names.contains("menu-ready") && names.contains("onboarding-welcome") && names.contains { $0.hasPrefix("hud-") })
        for tab in SettingsTab.allCases { #expect(names.contains { $0.hasPrefix("settings-\(tab.rawValue)-") }, "\(tab.title)") }
        #expect(Snapshots.committedScenarios.map(\.name) == names)
    }

    @Test func theCommittedFilesAreExactlyTheCuratedSetUnderFourPointFiveMegabytes() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/screenshots/mac")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }   // not a full checkout
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.sorted()
        let expected = Snapshots.committedNames.flatMap { ["\($0)-dark.png", "\($0)-light.png"] }.sorted()
        #expect(files == expected, "docs/screenshots/mac is out of date: run mac/scripts/snapshots.sh")
        let total = try files.reduce(0) { $0 + (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($1).path)[.size] as? Int ?? 0) }
        #expect(total < 4_500_000, "\(total) bytes")
    }

    @Test func curatedRenderingWritesOnlyTheCommittedNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-curated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try Snapshots.render(to: dir, scenarios: Snapshots.committedScenarios)
        #expect(Set(files.map(\.lastPathComponent)) == Set(Snapshots.committedNames.flatMap { ["\($0)-dark.png", "\($0)-light.png"] }))
    }

    @Test func theMenuSnapshotsUseTheRealRowsSoHighlightAndValuesRender() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-menu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try Snapshots.render(to: dir, scenarios: Snapshots.menuScenarios.filter { ["menu-ready", "menu-hover"].contains($0.name) })
        let ready = try Data(contentsOf: dir.appendingPathComponent("menu-ready-light.png"))
        let hover = try Data(contentsOf: dir.appendingPathComponent("menu-hover-light.png"))
        #expect(ready != hover)   // the hover scenario draws a selected row
    }
}
