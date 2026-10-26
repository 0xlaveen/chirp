import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// The Pond design system (#151 §C) on iOS: the same token names and values as the Mac's
// `ChirpUI/Theme.swift` and Android's `ui/ChirpTheme.kt`, so the three apps read as one product.
//
// This file imports SwiftUI/UIKit only (never ChirpCore), so the widget extension can compile it in
// directly. The AppKit branch exists only so the package's tests build and run on the Mac host.

/// The Pond colour tokens as dynamic light/dark colours: `Color.chirp.koi`, `Color.chirp.surface`, …
///
/// Body text keeps `.primary`/`.secondary`, so Increase Contrast still works; these tokens cover the
/// brand surfaces and accents the system has no equivalent for. System controls pick koi up from the
/// app's `AccentColor` asset.
public enum ChirpColor {
    public typealias RGB = (r: Double, g: Double, b: Double)

    static func hex(_ value: UInt32) -> RGB {
        (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// Every token's light and dark values, so the tests can pin them to the #151 table and check contrast.
    public enum Pond {
        /// Screen backgrounds, including Form/List via `.scrollContentBackground(.hidden)`.
        public static let background = (light: ChirpColor.hex(0xF6F7FA), dark: ChirpColor.hex(0x0D1526))
        /// Cards and list rows.
        public static let surface = (light: ChirpColor.hex(0xFFFFFF), dark: ChirpColor.hex(0x121C30))
        /// Grouped settings rows, chips, the search field.
        public static let surfaceRaised = (light: ChirpColor.hex(0xECEFF5), dark: ChirpColor.hex(0x1A2640))
        /// Primary text on Pond surfaces (body text keeps `.primary`).
        public static let ink = (light: ChirpColor.hex(0x1A2333), dark: ChirpColor.hex(0xE8ECF3))
        /// Snippets and meta text on Pond surfaces.
        public static let inkMuted = (light: ChirpColor.hex(0x5B6577), dark: ChirpColor.hex(0xA3ADBF))
        /// The brand accent: primary buttons, selection, links, focus. Also the app's AccentColor.
        public static let koi = (light: ChirpColor.hex(0xC2410C), dark: ChirpColor.hex(0xFF8A4C))
        /// Ripple rings and large shapes only, never body text.
        public static let koiDecor = (light: ChirpColor.hex(0xF26A1B), dark: ChirpColor.hex(0xFF8A4C))
        /// Selected rows and tonal buttons.
        public static let koiContainer = (light: ChirpColor.hex(0xFFE4D4), dark: ChirpColor.hex(0x5C2207))
        public static let onKoiContainer = (light: ChirpColor.hex(0x7A2A08), dark: ChirpColor.hex(0xFFD9C2))
        /// The koi fill is dark in light mode (white text on it) and light in dark mode (pond ink on it).
        public static let onKoi = (light: ChirpColor.hex(0xFFFFFF), dark: ChirpColor.hex(0x0D1526))
        /// AI/polish text colour (Organize, Polishing…, Polished, "Edited")…
        public static let moon = (light: ChirpColor.hex(0x8A5A00), dark: ChirpColor.hex(0xF5C566))
        /// …and the golden fill those come on.
        public static let moonFill = (light: ChirpColor.hex(0xF5C566), dark: ChirpColor.hex(0xF5C566))
        /// Success and decisions (the Connected dot, done checks).
        public static let lily = (light: ChirpColor.hex(0x2F7A4F), dark: ChirpColor.hex(0x7CCB9B))
        /// The record/stop dot, Stop, errors and the DEBUG banner only.
        public static let record = (light: ChirpColor.hex(0xD93636), dark: ChirpColor.hex(0xFF6B6B))
        /// Warning banners ("Computer offline", "Computer loading"): Android's tertiaryContainer pair, a moon-gold fill…
        public static let warningContainer = (light: ChirpColor.hex(0xF5C566), dark: ChirpColor.hex(0x4E3B00))
        /// …and the ink on it.
        public static let onWarningContainer = (light: ChirpColor.hex(0x402D00), dark: ChirpColor.hex(0xF5C566))
    }

    #if canImport(UIKit)
    static func dynamic(_ light: RGB, _ dark: RGB) -> UIColor {
        UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        }
    }

    static func color(_ light: RGB, _ dark: RGB) -> Color { Color(uiColor: dynamic(light, dark)) }
    #else
    static func dynamic(_ light: RGB, _ dark: RGB) -> NSColor {
        NSColor(name: "ChirpPond") { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        }
    }

    static func color(_ light: RGB, _ dark: RGB) -> Color { Color(nsColor: dynamic(light, dark)) }
    #endif

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
    public static let warningContainer = color(Pond.warningContainer.light, Pond.warningContainer.dark)
    public static let onWarningContainer = color(Pond.onWarningContainer.light, Pond.onWarningContainer.dark)

    #if canImport(UIKit)
    /// The koi accent for UIKit tints (the same dynamic colour as `koi`).
    public static let koiAccent = dynamic(Pond.koi.light, Pond.koi.dark)
    #endif
}

public extension Color {
    /// The Pond tokens: `Color.chirp.koi`, `Color.chirp.inkMuted`, …
    static var chirp: ChirpColor.Type { ChirpColor.self }
}

/// The Pond spacing grid (4-point: 4, 8, 12, 16, 24, 32, 48) and the content gutters.
public enum ChirpSpacing {
    public static let s4: CGFloat = 4
    public static let s8: CGFloat = 8
    public static let s12: CGFloat = 12
    public static let s16: CGFloat = 16
    public static let s24: CGFloat = 24
    public static let s32: CGFloat = 32
    public static let s48: CGFloat = 48
    /// The content gutter at compact width (iPhone, slim iPad windows).
    public static let gutterCompact: CGFloat = 16
    /// The content gutter at regular width (iPad).
    public static let gutterRegular: CGFloat = 24

    /// The content gutter for a horizontal size class: 16 on iPhone, 24 at regular width.
    public static func gutter(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? gutterRegular : gutterCompact
    }
}

/// The Pond corner radii (pair with `.continuous` corners). Chips, docks and search fields are capsules.
public enum ChirpRadius {
    /// Controls and keycaps.
    public static let control: CGFloat = 6
    /// Rows and callouts.
    public static let row: CGFloat = 10
    /// Panels and cards.
    public static let panel: CGFloat = 16
    /// Sheets.
    public static let sheet: CGFloat = 28
}

/// The Pond type. Chrome stays SF Pro; note titles, the Notes large title and library section headers
/// use the New York serif; timers use tabular digits so they don't jitter as they tick. Every style is
/// a Dynamic Type text style, never a fixed size, so it follows the user's text size up to AX5.
public enum ChirpType {
    /// A note title: New York, title, semibold.
    public static let noteTitle: Font = .system(.title, design: .serif).weight(.semibold)
    /// A library section header ("Today", "Previous 7 days"): New York, title 3, semibold.
    public static let sectionHeader: Font = .system(.title3, design: .serif).weight(.semibold)
    /// A heading inside a note.
    public static let h2: Font = .title3.weight(.semibold)
    /// A library row title.
    public static let listTitle: Font = .headline
    /// A library meta line.
    public static let meta: Font = .footnote
    /// Timer text with tabular digits.
    public static func timer(_ style: Font.TextStyle = .body) -> Font { .system(style).monospacedDigit() }
}

/// The brand artwork, shipped verbatim in the app's asset catalog (never traced or redrawn).
public enum ChirpBrand {
    /// The round-bird glyph (`ChirpGlyph`, copied from `mac/Assets/ChirpGlyph.png`), template-rendered so
    /// `foregroundStyle` tints it. Size it with `.resizable().scaledToFit().frame(…)`.
    public static var glyph: Image { Image("ChirpGlyph") }
    /// The pond artwork from the app icon (`PondArt`): the welcome hero.
    public static var pond: Image { Image("PondArt") }
}
