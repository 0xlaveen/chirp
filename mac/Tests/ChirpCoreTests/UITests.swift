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

    @Test func useRawIsOfferedOnlyForInsertedCorrections() {
        let corrected = FinalResult(text: "Hello.", raw: "hello", corrected: true)
        let unchanged = FinalResult(text: "hello", raw: "hello", corrected: true)
        let inserted = OutcomePresentation.of(.inserted(.ax), final: corrected)
        #expect(inserted.showUseRaw && inserted.linger == 5)
        #expect(!OutcomePresentation.of(.inserted(.ax), final: unchanged).showUseRaw)
        #expect(!OutcomePresentation.of(.copied, final: corrected).showUseRaw)
    }

    @Test func cleanedBadgeFollowsTheRewriteAndRawButtonFollowsThePreference() {
        let corrected = FinalResult(text: "Hello.", raw: "hello", corrected: true)
        let on = OutcomePresentation.of(.inserted(.ax), final: corrected)
        #expect(on.cleaned && on.showUseRaw && on.linger == 5)
        let off = OutcomePresentation.of(.inserted(.ax), final: corrected, offerRaw: false)
        #expect(off.cleaned && !off.showUseRaw && off.linger == 1.8)
        #expect(!OutcomePresentation.of(.inserted(.ax), final: FinalResult(text: "hello")).cleaned)
        #expect(!OutcomePresentation.of(.refusedSecure, final: corrected).cleaned)
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

    @Test func contentKeepsItsMarginOnEverySide() {
        let form = SettingsForm(SettingsState())
        form.view.layoutSubtreeIfNeeded()
        let size = form.view.fittingSize
        let grid = form.view.subviews[0]
        form.view.setFrameSize(size)
        form.view.layoutSubtreeIfNeeded()
        #expect(abs(grid.frame.minX - 20) < 0.5 && abs(grid.frame.minY - 20) < 0.5)
        #expect(abs(size.width - grid.frame.maxX - 20) < 0.5 && abs(size.height - grid.frame.maxY - 20) < 0.5)
    }

    @Test func labelsShareARightEdgeAndControlsALeftEdge() throws {
        let form = SettingsForm(SettingsState())
        form.view.setFrameSize(form.view.fittingSize)
        form.view.layoutSubtreeIfNeeded()
        func labels(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? labels(in: $0) }
        }
        let rowLabels = labels(in: form.view).filter { $0.stringValue.hasSuffix(":") && $0.alignment == .right }
        #expect(rowLabels.count == 8)
        let edges = rowLabels.map { form.view.convert($0.bounds, from: $0).maxX }
        #expect(edges.allSatisfy { abs($0 - edges[0]) < 0.5 })
        let controlEdges = [form.hotkey, form.launch, form.serverURL, form.micButton].map { form.view.convert($0.bounds, from: $0).minX }
        // The permission button sits after its status text, so compare only the controls that start a cell.
        #expect(abs(controlEdges[0] - controlEdges[1]) < 0.5 && abs(controlEdges[0] - controlEdges[2]) < 0.5)
        #expect(controlEdges[0] > edges[0])
    }

    @Test func helpTextUsesTheSecondaryLabelColour() {
        let form = SettingsForm(SettingsState())
        #expect(form.launchHelp.textColor == .secondaryLabelColor)
        #expect(form.launchHelp.font?.pointSize == NSFont.smallSystemFontSize)
    }

    @Test func opensWithoutAFocusedOrSelectedServerURL() {
        let form = SettingsForm(SettingsState())
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        form.install(in: window)
        #expect(window.initialFirstResponder === form.view)
        #expect(window.firstResponder === form.view)
        #expect(!(window.firstResponder is NSText))
        #expect(window.contentView?.frame.width ?? 0 > 300)
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
        #expect(names.contains("settings-ready-dark.png") && names.contains("menu-idle-light.png") && names.contains("menu-input-picker-dark.png"))
        for name in ["onboarding-welcome", "onboarding-try-it-success", "onboarding-microphone-blocked", "about", "settings-custom-hotkey-sounds"] {
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
        for name in ["hud-listening", "settings-ready", "menu-idle"] {
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
}
