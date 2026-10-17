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

    public static func tint(_ tone: MenuEntry.Tone) -> NSColor? {
        switch tone {
        case .normal: nil
        case .ok: .systemGreen
        case .active: .controlAccentColor
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

/// The menu's header block: app icon, name, hotkey hint and the status lines, in primary text colours. A disabled
/// `NSMenuItem` is always drawn greyed out by AppKit (attributed colours are ignored), so this is a custom view.
@MainActor
public final class MenuHeaderView: NSView {
    private static let inset: CGFloat = 14
    private static let iconSize: CGFloat = 32
    private static let textWidth: CGFloat = 300

    /// `lines` are the rows after the title and hint (the status, the debug-retention warning).
    public init(title: String, hint: String?, lines: [MenuEntry], icon: NSImage?) {
        super.init(frame: .zero)
        autoresizingMask = [.width]

        let titleLabel = Self.label(title, font: MenuStyle.semiboldFont, color: .labelColor)
        var rows: [NSView] = [titleLabel]
        if let hint { rows.append(Self.label(hint, font: MenuStyle.secondaryFont, color: .secondaryLabelColor)) }
        for line in lines { rows.append(Self.statusRow(line)) }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        if rows.count > 2 { stack.setCustomSpacing(6, after: rows[1]) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let iconView = NSImageView(image: icon ?? NSImage())
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityElement(false)
        addSubview(iconView)

        let trailing = trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: Self.inset)
        trailing.priority = .defaultHigh   // the menu may make the view wider than its content
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            stack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 8),
            trailing,
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(([title, hint].compactMap { $0 } + lines.map(\.title)).joined(separator: ", "))

        // Set the frame before any layout pass, so the autoresizing constraints are made from it, not from zero.
        let size = fittingSize
        setFrameSize(size)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = font
        f.textColor = color
        f.maximumNumberOfLines = 2
        f.preferredMaxLayoutWidth = textWidth
        f.setAccessibilityElement(false)
        return f
    }

    /// A status line: the symbol in its tone's colour, the text in primary contrast (red only for errors).
    private static func statusRow(_ line: MenuEntry) -> NSView {
        let text = label(line.title, font: MenuStyle.font, color: MenuStyle.textColor(line.tone))
        text.preferredMaxLayoutWidth = textWidth - 16
        guard let name = line.symbol else { return text }
        let image = NSImageView(image: MenuStyle.symbol(name, tone: line.tone) ?? NSImage())
        image.setContentHuggingPriority(.required, for: .horizontal)
        image.widthAnchor.constraint(equalToConstant: 10).isActive = true
        image.setAccessibilityElement(false)
        let row = NSStackView(views: [image, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }
}
