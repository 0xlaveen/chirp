import AppKit

/// Plain-value copy of the NSScreen numbers the layout needs, so the maths can be tested with fake inputs.
struct ScreenMetrics: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    var safeAreaTop: CGFloat
    var auxLeft: CGRect?
    var auxRight: CGRect?

    @MainActor init(_ s: NSScreen) {
        frame = s.frame
        visibleFrame = s.visibleFrame
        safeAreaTop = s.safeAreaInsets.top
        auxLeft = s.auxiliaryTopLeftArea
        auxRight = s.auxiliaryTopRightArea
    }

    init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat, auxLeft: CGRect?, auxRight: CGRect?) {
        self.frame = frame; self.visibleFrame = visibleFrame; self.safeAreaTop = safeAreaTop
        self.auxLeft = auxLeft; self.auxRight = auxRight
    }

    var hasRealNotch: Bool { safeAreaTop > 0 && auxLeft != nil && auxRight != nil }
    /// Height of the menu bar strip (0 when it is hidden, e.g. in a full-screen Space).
    var menuBarHeight: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }

    /// Fake metrics shaped like a notched MacBook, for running the layout code on a plain display.
    static func fake(_ preset: SimNotch, on base: ScreenMetrics) -> ScreenMetrics {
        let f = base.frame
        let nw = preset.notchSize.width, nh = preset.notchSize.height
        let left = CGRect(x: f.minX, y: f.maxY - nh, width: (f.width - nw) / 2, height: nh)
        let right = CGRect(x: f.midX + nw / 2, y: f.maxY - nh, width: (f.width - nw) / 2, height: nh)
        return ScreenMetrics(frame: f, visibleFrame: base.visibleFrame, safeAreaTop: nh, auxLeft: left, auxRight: right)
    }
}

enum SimNotch: String, CaseIterable, Sendable {
    case off = "Off (real hardware numbers)"
    case mbp14 = "Simulated 14\" notch (200 x 32)"
    case mbp16 = "Simulated 16\" notch (200 x 32)"
    /// Approximate. A real 14"/16" notch is ~200 pt wide and 32 pt tall; the README says to compare against the
    /// numbers printed on real hardware and correct these.
    var notchSize: CGSize { CGSize(width: 200, height: 32) }
}

enum IslandMode: String, Sendable { case notch, floating }

struct NotchLayout: Equatable {
    var mode: IslandMode
    /// Notch cutout in global screen coordinates (nil when floating).
    var notchRect: CGRect?
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    /// Where the fixed-size panel goes, in global screen coordinates.
    var panelFrame: CGRect
}

enum NotchGeometry {
    static let panelSize = CGSize(width: 520, height: 150)
    static let floatingGap: CGFloat = 10

    /// Pure layout from screen numbers. The panel is positioned from `frame` (not `visibleFrame`) because it
    /// has to sit over the menu bar / notch.
    static func layout(_ m: ScreenMetrics, panelSize: CGSize = panelSize) -> NotchLayout {
        if m.hasRealNotch, let l = m.auxLeft, let r = m.auxRight {
            let notch = CGRect(x: l.maxX, y: m.frame.maxY - m.safeAreaTop, width: r.minX - l.maxX, height: m.safeAreaTop)
            let panel = CGRect(x: notch.midX - panelSize.width / 2, y: m.frame.maxY - panelSize.height,
                               width: panelSize.width, height: panelSize.height)
            return NotchLayout(mode: .notch, notchRect: notch, notchWidth: notch.width, notchHeight: notch.height, panelFrame: panel)
        }
        let panel = CGRect(x: m.frame.midX - panelSize.width / 2, y: m.frame.maxY - panelSize.height,
                           width: panelSize.width, height: panelSize.height)
        return NotchLayout(mode: .floating, notchRect: nil, notchWidth: 0, notchHeight: 0, panelFrame: panel)
    }
}

enum IslandState: String, CaseIterable, Sendable {
    case listening, polishing, done

    /// Sizes from the prototype's ISLAND_SIZES (listening 380x34 r20, polishing 430x84 r26, done 360x34 r20).
    var size: (w: CGFloat, h: CGFloat, r: CGFloat) {
        switch self {
        case .listening: (380, 34, 20)
        case .polishing: (430, 84, 26)
        case .done: (360, 34, 20)
        }
    }
}
