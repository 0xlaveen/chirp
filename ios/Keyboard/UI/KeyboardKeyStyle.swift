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

/// A typing key that looks like the system keyboard's: a raised keycap with a 6 pt radius and the one-pixel shadow
/// under it (white letter keys and grey function keys in light, two greys in dark).
class KeyCapButton: UIButton {
    enum Kind { case letter, function }
    var kind: Kind = .letter { didSet { setNeedsUpdateConfiguration() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: ChirpRadius.control).cgPath
    }

    static func background(_ kind: Kind, pressed: Bool, dark: Bool) -> UIColor {
        switch (kind, dark, pressed) {
        case (.letter, false, false), (.function, false, true): UIColor(white: 1, alpha: 1)
        case (.function, false, false), (.letter, false, true): UIColor(red: 0.675, green: 0.702, blue: 0.737, alpha: 1)
        case (.letter, true, false), (.function, true, true): UIColor(white: 0.42, alpha: 1)
        case (.function, true, false), (.letter, true, true): UIColor(white: 0.28, alpha: 1)
        }
    }
}

enum KeyboardKeyStyle {
    /// Configures a key: no system tint, the keycap fill from `KeyCapButton.background`, a Dynamic Type title capped
    /// so it fits the fixed key height.
    static func apply(to key: KeyCapButton, kind: KeyCapButton.Kind, title: String?, symbol: String?) {
        key.kind = kind
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 4
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .fixed
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .body)
                .scaledFont(for: .systemFont(ofSize: 17), maximumPointSize: KeyboardMetrics.maxKeyTextPoints)
            return attributes
        }
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        key.configuration = configuration
        key.titleLabel?.adjustsFontForContentSizeCategory = true
        key.configurationUpdateHandler = { button in
            guard let key = button as? KeyCapButton else { return }
            var configuration = key.configuration
            let dark = key.traitCollection.userInterfaceStyle == .dark
            configuration?.background.backgroundColor = KeyCapButton.background(key.kind, pressed: key.isHighlighted, dark: dark)
            configuration?.background.cornerRadius = ChirpRadius.control
            key.configuration = configuration
        }
        key.setNeedsUpdateConfiguration()
    }
}
