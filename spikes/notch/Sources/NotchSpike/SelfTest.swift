import AppKit
import SwiftUI

@MainActor
enum SelfTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        report("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }
    static func spin(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    static func run(_ c: Controller) -> Never {
        quiet = !CommandLine.arguments.contains("--verbose")
        geometry()
        live(c)
        report(failures == 0 ? "\nSELFTEST OK" : "\nSELFTEST FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    static func geometry() {
        report("--- geometry with fake inputs")
        let base = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                 visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 880), safeAreaTop: 0, auxLeft: nil, auxRight: nil)
        let none = NotchGeometry.layout(base)
        check(none.mode == .floating && none.notchRect == nil, "no notch -> floating mode")
        check(none.panelFrame.midX == 756 && none.panelFrame.maxY == 982, "floating panel centred on frame, flush with screen top")

        let fake14 = ScreenMetrics.fake(.mbp14, on: base)
        let l14 = NotchGeometry.layout(fake14)
        check(l14.mode == .notch, "fake 14\" -> notch mode")
        check(l14.notchWidth == 200 && l14.notchHeight == 32, "fake 14\" notch is 200x32 (got \(l14.notchWidth)x\(l14.notchHeight))")
        check(l14.notchRect == CGRect(x: 656, y: 950, width: 200, height: 32), "notch rect in global coords \(String(describing: l14.notchRect))")
        check(l14.panelFrame.midX == 756 && l14.panelFrame.maxY == 982 && l14.panelFrame.size == NotchGeometry.panelSize, "panel centred on notch, top flush with frame.maxY, fixed size")

        // 16": wider screen, notch off-centre by 0 but different origin (second display to the right of the first)
        let b16 = ScreenMetrics(frame: CGRect(x: 1512, y: -135, width: 1728, height: 1117),
                                visibleFrame: CGRect(x: 1512, y: -65, width: 1728, height: 1050), safeAreaTop: 0, auxLeft: nil, auxRight: nil)
        let l16 = NotchGeometry.layout(ScreenMetrics.fake(.mbp16, on: b16))
        check(l16.panelFrame.midX == 1512 + 864 && l16.panelFrame.maxY == 982, "16\" at non-zero origin: panel x/y follow the screen")

        // asymmetric aux areas (real hardware can be off by sub-point amounts)
        let asym = ScreenMetrics(frame: base.frame, visibleFrame: base.visibleFrame, safeAreaTop: 32,
                                 auxLeft: CGRect(x: 0, y: 950, width: 656, height: 32), auxRight: CGRect(x: 859, y: 950, width: 653, height: 32))
        let la = NotchGeometry.layout(asym)
        check(la.notchWidth == 203 && la.panelFrame.midX == 757.5, "notch width = auxRight.minX - auxLeft.maxX; panel centred on the notch, not the screen")
        check(base.menuBarHeight == 982 - 950, "menuBarHeight = frame.maxY - visibleFrame.maxY (\(base.menuBarHeight))")
    }

    static func live(_ c: Controller) {
        report("--- live panel on this machine (\(NSScreen.screens.count) screen(s); real notch: \(NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }))")
        c.model.sim = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } ? .off : .mbp14
        let frontStart = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        report("frontmost app at start: \(frontStart ?? "nil")")
        let size0 = c.panel.frame.size
        var drifts: [String] = []
        for l in LevelChoice.all {
            c.model.levelIndex = LevelChoice.all.firstIndex { $0.name == l.name }!
            c.apply(reason: "selftest level=\(l.name)"); spin(0.3)
            check(c.panel.level == l.level, "level \(l.name) applied")
            check(!c.panel.isKeyWindow && !c.panel.isMainWindow, "level \(l.name): panel is not key/main")
            check(!c.lastStole, "level \(l.name): focus not stolen (frontmost still \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"))")
            check(!c.lastDrift, "level \(l.name): AppKit did not move the panel (frame == expected) with constrainFrameRect overridden")
            check(c.panel.isVisible, "level \(l.name): panel is visible")
        }
        check(c.model.focusEvents == 0, "no didBecomeKey / didBecomeActive events during level sweep (\(c.model.focusEvents))")

        c.model.levelIndex = LevelChoice.all.firstIndex { $0.name == "statusBar" }!
        for s in IslandState.allCases {
            c.setState(s); spin(0.5)
            check(c.panel.frame.size == size0, "state \(s.rawValue): panel stays fixed-size \(c.panel.frame.size) (NSHostingView sizingOptions = [])")
        }

        // What AppKit does by default, for the README (informational, not a failure either way)
        c.panel.allowConstrain = true
        for name in ["statusBar", "mainMenu", "popUpMenu"] {
            c.model.levelIndex = LevelChoice.all.firstIndex { $0.name == name }!
            c.apply(reason: "selftest default-constrain level=\(name)"); spin(0.3)
            drifts.append("\(name): \(c.lastDrift ? "AppKit MOVED the panel (frame != screen top)" : "frame unchanged")")
        }
        c.panel.allowConstrain = false
        report("INFO  default constrainFrameRect behaviour on this display -> " + drifts.joined(separator: "; "))

        // Every behaviour combination applies without raising.
        let flags = BehaviourChoice.all
        for mask in 0..<(1 << flags.count) {
            c.model.behaviours = Set(flags.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            c.apply(reason: "selftest behaviours mask=\(mask)", orderFront: true); spin(0.05)
        }
        check(true, "all 16 collection-behaviour combinations applied without an exception")
        check(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == frontStart, "frontmost app unchanged after the whole run")
        check(c.model.focusEvents == 0, "still zero focus events at the end (\(c.model.focusEvents))")
    }
}
