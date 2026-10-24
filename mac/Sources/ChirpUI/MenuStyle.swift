import AppKit

/// Fonts, colours and symbol sizing the menu-bar menu and its custom views share, so every row reads as one system.
@MainActor
public enum MenuStyle {
    /// The standard control font: 13 pt. Secondary lines use `secondaryFont`.
    public static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    public static let semiboldFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    public static let secondaryFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    public static func textColor(_ tone: MenuEntry.Tone) -> NSColor {
        switch tone {
        case .error: .systemRed
        case .warning: .systemOrange
        default: .labelColor
        }
    }

    /// The status line's colour: secondary grey, red or orange when something is wrong.
    public static func secondaryTextColor(_ tone: MenuEntry.Tone) -> NSColor {
        switch tone {
        case .error: .systemRed
        case .warning: .systemOrange
        default: .secondaryLabelColor
        }
    }

    public static func tint(_ tone: MenuEntry.Tone) -> NSColor? {
        switch tone {
        case .normal: nil
        case .ok: .systemGreen
        case .active: .chirpKoi
        case .warning: .systemOrange
        case .error: .systemRed
        }
    }

    /// An SF Symbol at one weight and scale for every row; the status dot is smaller so it sits like a bullet.
    public static func symbol(_ name: String, tone: MenuEntry.Tone = .normal, description: String? = nil) -> NSImage? {
        let isDot = name == "circle.fill"
        var config = NSImage.SymbolConfiguration(pointSize: isDot ? 8 : 13, weight: .regular, scale: isDot ? .small : .medium)
        if let color = tint(tone) {
            // Badge symbols (a mark on a filled shape) keep the mark white on the tinted shape.
            let badge = name == "checkmark.circle.fill" || name == "exclamationmark.triangle.fill"
            config = config.applying(.init(paletteColors: badge ? [.white, color] : [color]))
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(config)
    }
}
