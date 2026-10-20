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

    @Test func hasFiveTabsInTheTargetOrder() {
        #expect(SettingsTab.allCases.map(\.title) == ["General", "Sounds", "Clean-up", "Server", "Permissions"])
        #expect(SettingsTab.allCases.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil })
    }

    @Test func eachControlLivesOnItsOwnTab() {
        let form = SettingsForm(SettingsState())
        func has(_ control: NSView, _ tab: SettingsTab) -> Bool { control.isDescendant(of: form.view(for: tab)) }
        #expect(has(form.hotkey, .general) && has(form.recorder, .general) && has(form.launch, .general) && has(form.setupButton, .general))
        #expect(has(form.wordWaveform, .general) && !has(form.wordWaveform, .cleanup))
        #expect(has(form.sounds, .sounds) && has(form.soundPack, .sounds) && has(form.volume, .sounds) && has(form.chooseStart, .sounds))
        #expect(has(form.cleanupEnabled, .cleanup) && has(form.style, .cleanup) && has(form.prompts.view, .cleanup))
        #expect(has(form.appStyles.view, .cleanup) && has(form.showChanges, .cleanup) && has(form.insertRawFirst, .cleanup))
        #expect(has(form.serverURL, .server) && has(form.doctorButton, .server))
        #expect(has(form.micButton, .permissions) && has(form.accessibilityButton, .permissions))
        // and on no other
        #expect(!has(form.launch, .server) && !has(form.serverURL, .general) && !has(form.hotkey, .sounds) && !has(form.micButton, .general))
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

    @Test func everyTabIsSizedToItsContent() {
        let form = SettingsForm(SettingsState())
        let sizes = SettingsTab.allCases.map { form.fittingSize(for: $0) }
        #expect(sizes.allSatisfy { $0.width > 300 && $0.height > 80 })
        // Not one tall form any more: only Clean-up (the prompt editor) is tall.
        let heights = Dictionary(uniqueKeysWithValues: zip(SettingsTab.allCases, sizes.map(\.height)))
        #expect(heights[.general]! < 380 && heights[.permissions]! < 200 && heights[.server]! < 300 && heights[.sounds]! < 360, "\(heights)")
        #expect(heights[.cleanup]! > heights[.general]! * 2)
        // Each is fitted on its own: the sizes differ.
        #expect(Set(sizes.map(\.height)).count == sizes.count)
    }

    @Test func contentKeepsItsMarginOnEverySide() {
        let form = SettingsForm(SettingsState())
        for tab in SettingsTab.allCases {
            let view = form.view(for: tab)
            let size = form.fittingSize(for: tab)
            let grid = view.subviews[0]
            view.setFrameSize(size)
            view.layoutSubtreeIfNeeded()
            #expect(abs(grid.frame.minX - 20) < 0.5 && abs(grid.frame.minY - 20) < 0.5, "\(tab.title)")
            #expect(abs(size.width - grid.frame.maxX - 20) < 0.5 && abs(size.height - grid.frame.maxY - 20) < 0.5, "\(tab.title)")
        }
    }

    @Test(arguments: [(SettingsTab.general, SoundPack.chirp, 6), (.sounds, .chirp, 3), (.sounds, .custom, 5), (.cleanup, .chirp, 8),
                      (.server, .chirp, 5), (.permissions, .chirp, 2)])
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
        case .general: [form.hotkey, form.mode, form.silence, form.wordWaveform, form.launch, form.setupButton]
        case .sounds: [form.sounds, form.soundPack, form.volume]
        case .cleanup: [form.cleanupEnabled, form.style, form.insertRawFirst, form.appStyles.scroll, form.showChanges, form.offerRaw]
        case .server: [form.serverURL, form.doctorButton, form.modelsButton]
        case .permissions: []
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

    @Test func customSoundRowsChangeOnlyTheSoundsTab() throws {
        let form = SettingsForm(SettingsState())
        let controller = SettingsTabs.makeController(form: form)
        let sounds = try #require(controller.tabViewItems[1].viewController as? SettingsTabController)
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
                     action: MenuAction? = .showAbout) -> MenuRowView {
        MenuRowView(entry: MenuEntry(title: title, value: value, shortcut: shortcut, action: action,
                                     submenu: submenu ? [MenuEntry(title: "x", action: .showAbout)] : nil))
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
                                             submenu: [MenuEntry(title: "x", action: .showAbout)]))
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
        for name in ["onboarding-welcome", "onboarding-try-it-success", "onboarding-microphone-blocked", "about", "settings-general-custom-hotkey"] {
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
        #expect(names.count * 2 <= 30)
        // The menu in light and dark, one per Settings tab, setup, and the key HUD states.
        #expect(names.contains("menu-ready") && names.contains("onboarding-welcome") && names.contains { $0.hasPrefix("hud-") })
        for tab in SettingsTab.allCases { #expect(names.contains { $0.hasPrefix("settings-\(tab.rawValue)-") }, "\(tab.title)") }
        #expect(Snapshots.committedScenarios.map(\.name) == names)
    }

    @Test func theCommittedFilesAreExactlyTheCuratedSetUnderThreeMegabytes() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/screenshots/mac")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }   // not a full checkout
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.sorted()
        let expected = Snapshots.committedNames.flatMap { ["\($0)-dark.png", "\($0)-light.png"] }.sorted()
        #expect(files == expected, "docs/screenshots/mac is out of date: run mac/scripts/snapshots.sh")
        let total = try files.reduce(0) { $0 + (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($1).path)[.size] as? Int ?? 0) }
        #expect(total < 3_000_000, "\(total) bytes")
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
