import UIKit
import ChirpIOSCore
import KeyboardPolicy

/// Pond colours as dynamic `UIColor`s for the keyboard's UIKit views. The values are the shared `ChirpColor.Pond`
/// table, so the keyboard can never drift from the app, Mac and Android.
enum KeyboardPalette {
    static func color(_ pair: (light: ChirpColor.RGB, dark: ChirpColor.RGB)) -> UIColor {
        UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? pair.dark : pair.light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        }
    }

    static let koi = color(ChirpColor.Pond.koi)
    static let onKoi = color(ChirpColor.Pond.onKoi)
    static let koiDecor = color(ChirpColor.Pond.koiDecor)
    static let koiContainer = color(ChirpColor.Pond.koiContainer)
    static let onKoiContainer = color(ChirpColor.Pond.onKoiContainer)
    static let moon = color(ChirpColor.Pond.moon)
    static let moonFill = color(ChirpColor.Pond.moonFill)
    static let record = color(ChirpColor.Pond.record)
    static let surface = color(ChirpColor.Pond.surface)
    static let surfaceRaised = color(ChirpColor.Pond.surfaceRaised)
    static let ink = color(ChirpColor.Pond.ink)
    static let inkMuted = color(ChirpColor.Pond.inkMuted)
    /// Ink on the `moonFill` while polishing: dark in both modes, because the moon fill is gold in both.
    static let onMoonFill = UIColor(red: 0x40 / 255, green: 0x2D / 255, blue: 0, alpha: 1)
    /// Ink on the `record` Stop fill: white on the light red, pond ink on the dark mode's light red.
    static let onRecord = color((light: (r: 1, g: 1, b: 1), dark: (r: 0x0D / 255.0, g: 0x15 / 255.0, b: 0x26 / 255.0)))
}
