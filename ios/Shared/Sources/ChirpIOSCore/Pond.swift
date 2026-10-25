import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Pond design system on iOS: the same semantic tokens as `mac/Sources/ChirpUI/Theme.swift` and
/// Android's `ChirpTheme.kt` (#151 §C), under the same names.
///
/// Colour tokens are dynamic light/dark colours (`UIColor(dynamicProvider:)` wrapped in `Color`), so they
/// resolve live with the appearance. Body text keeps `.primary`/`.secondary` so Increase Contrast and
/// Dynamic Type keep working; these tokens cover the brand surfaces and accents the system has no
/// equivalent for.
///
/// This file imports only SwiftUI and UIKit and uses nothing from `ChirpCore`, so the widget target can
/// compile it too. (The AppKit branch exists only so `swift test` builds the package on the host Mac.)
///
/// The keyboard extension has no asset catalog (only the app ships `Assets.xcassets`, with
/// `ChirpGlyph`/`PondArt`/`AccentColor`); it draws the brand mark with SF Symbols until #195 decides
/// whether the glyph is worth a second catalog in the extension's memory budget.
public enum ChirpColor {
    public typealias RGB = (r: Double, g: Double, b: Double)

    static func hex(_ value: UInt32) -> RGB {
        (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// Every token's light and dark values, so the tests can pin them to the #151 table and check contrast.
    public enum Pond {
        /// Screen background.
        public static let background = (light: ChirpColor.hex(0xF6F7FA), dark: ChirpColor.hex(0x0D1526))
        /// Cards and list rows.
        public static let surface = (light: ChirpColor.hex(0xFFFFFF), dark: ChirpColor.hex(0x121C30))
        /// Grouped settings rows, chips and the search field.
        public static let surfaceRaised = (light: ChirpColor.hex(0xECEFF5), dark: ChirpColor.hex(0x1A2640))
        /// Primary text.
        public static let ink = (light: ChirpColor.hex(0x1A2333), dark: ChirpColor.hex(0xE8ECF3))
        /// Snippets and meta text.
        public static let inkMuted = (light: ChirpColor.hex(0x5B6577), dark: ChirpColor.hex(0xA3ADBF))
        /// The brand accent: primary buttons, selection, links, focus. Also the app accent.
        public static let koi = (light: ChirpColor.hex(0xC2410C), dark: ChirpColor.hex(0xFF8A4C))
        /// Ripple rings and large shapes only, never body text.
        public static let koiDecor = (light: ChirpColor.hex(0xF26A1B), dark: ChirpColor.hex(0xFF8A4C))
        /// Selected rows and tonal buttons.
        public static let koiContainer = (light: ChirpColor.hex(0xFFE4D4), dark: ChirpColor.hex(0x5C2207))
        public static let onKoiContainer = (light: ChirpColor.hex(0x7A2A08), dark: ChirpColor.hex(0xFFD9C2))
        /// The koi fill is dark in light mode (white text on it) and light in dark mode (pond ink on it).
        public static let onKoi = (light: ChirpColor.hex(0xFFFFFF), dark: ChirpColor.hex(0x0D1526))
        /// AI/polish text colour (Organize, Polished, changed words)…
        public static let moon = (light: ChirpColor.hex(0x8A5A00), dark: ChirpColor.hex(0xF5C566))
        /// …and the golden fill those come on.
        public static let moonFill = (light: ChirpColor.hex(0xF5C566), dark: ChirpColor.hex(0xF5C566))
        /// Success and decisions (Connected, done checks).
        public static let lily = (light: ChirpColor.hex(0x2F7A4F), dark: ChirpColor.hex(0x7CCB9B))
        /// The record/stop dot and errors only.
        public static let record = (light: ChirpColor.hex(0xD93636), dark: ChirpColor.hex(0xFF6B6B))
    }

    static func color(_ light: RGB, _ dark: RGB) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        })
        #else
        Color(nsColor: NSColor(name: "ChirpPond") { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
        #endif
    }

    public static let background = color(Pond.background.light, Pond.background.dark)
    public static let surface = color(Pond.surface.light, Pond.surface.dark)
    public static let surfaceRaised = color(Pond.surfaceRaised.light, Pond.surfaceRaised.dark)
    public static let ink = color(Pond.ink.light, Pond.ink.dark)
    public static let inkMuted = color(Pond.inkMuted.light, Pond.inkMuted.dark)
    public static let koi = color(Pond.koi.light, Pond.koi.dark)
    public static let koiDecor = color(Pond.koiDecor.light, Pond.koiDecor.dark)
    public static let koiContainer = color(Pond.koiContainer.light, Pond.koiContainer.dark)
    public static let onKoiContainer = color(Pond.onKoiContainer.light, Pond.onKoiContainer.dark)
    public static let onKoi = color(Pond.onKoi.light, Pond.onKoi.dark)
    public static let moon = color(Pond.moon.light, Pond.moon.dark)
    public static let moonFill = color(Pond.moonFill.light, Pond.moonFill.dark)
    public static let lily = color(Pond.lily.light, Pond.lily.dark)
    public static let record = color(Pond.record.light, Pond.record.dark)
}

public extension Color {
    /// The Pond tokens: `Color.chirp.koi`, `Color.chirp.inkMuted`, …
    static var chirp: ChirpColor.Type { ChirpColor.self }
}

/// The Pond spacing grid (4-point: 4, 8, 12, 16, 24, 32, 48) and the screen gutter.
public enum ChirpSpacing {
    public static let s4: CGFloat = 4
    public static let s8: CGFloat = 8
    public static let s12: CGFloat = 12
    public static let s16: CGFloat = 16
    public static let s24: CGFloat = 24
    public static let s32: CGFloat = 32
    public static let s48: CGFloat = 48

    /// The screen-content gutter: 16 on iPhone (compact width), 24 at regular width.
    public static func gutter(_ horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat {
        horizontalSizeClass == .regular ? s24 : s16
    }
}

/// The Pond corner radii.
public enum ChirpRadius {
    /// Controls and keycaps.
    public static let control: CGFloat = 6
    /// Rows and callouts.
    public static let row: CGFloat = 10
    /// Cards and panels.
    public static let panel: CGFloat = 16
    /// Sheets.
    public static let sheet: CGFloat = 28
}

/// The Pond type helpers. Chrome stays SF Pro; note titles and library section headers use the New York
/// serif, and timers use tabular digits so they don't jitter as they tick. All of them are text styles,
/// so they follow Dynamic Type.
public enum ChirpType {
    /// A note title, and the Notes large title: New York serif, semibold.
    public static let noteTitle: Font = .system(.title, design: .serif).weight(.semibold)
    /// A library section header: New York serif, semibold.
    public static let sectionHeader: Font = .system(.title3, design: .serif).weight(.semibold)
    /// Timer text with tabular digits.
    public static func timer(_ style: Font.TextStyle = .body) -> Font {
        .system(style).monospacedDigit()
    }
}
