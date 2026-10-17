import AppKit

/// Measurements taken from the system's own menus (Tailscale's status menu is the reference): 24 pt rows, text 16 pt
/// from the left edge, shortcuts and chevrons 17 pt from the right, a 10 pt separator.
public enum MenuMetrics {
    public static let rowHeight: CGFloat = 24
    public static let leading: CGFloat = 16
    public static let trailing: CGFloat = 17
    public static let minimumWidth: CGFloat = 280
    public static let separatorHeight: CGFloat = 10
    /// The selection rectangle sits inside the menu edge, like the system's.
    public static let highlightInset: CGFloat = 6
    public static let highlightRadius: CGFloat = 6
    /// Room between a row's title and its value.
    public static let valueGap: CGFloat = 24
}

/// A top-level row of the menu: the title at the left and, right-aligned in secondary grey, the current value or the
/// shortcut, then a chevron when the row opens a submenu. Custom-drawn so every row shares one set of measurements
/// (AppKit draws neither a value nor a shortcut like this for a submenu). The value gives way first when the menu is
/// narrower than its text. Selection, activation and VoiceOver follow the system's rows.
@MainActor
public final class MenuRowView: NSView {
    public let entry: MenuEntry
    /// Draws the row selected, for the snapshots (the live menu asks its `NSMenuItem`).
    public var showsHighlight = false

    public init(entry: MenuEntry) {
        self.entry = entry
        super.init(frame: .zero)
        autoresizingMask = [.width]
        setFrameSize(NSSize(width: ceil(fittingWidth), height: MenuMetrics.rowHeight))
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(entry.accessibilityLabel)
        setAccessibilityEnabled(entry.isEnabled)
        if entry.submenu != nil { setAccessibilityHelp("Opens a submenu") }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override public var isFlipped: Bool { true }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override public var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: MenuMetrics.rowHeight) }

    private var isSelected: Bool { entry.isEnabled && (showsHighlight || enclosingMenuItem?.isHighlighted == true) }
    private var chevronWidth: CGFloat { entry.submenu == nil ? 0 : 7 + 9 }
    private var rightText: String? { entry.value ?? entry.shortcut }

    private func size(of text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: MenuStyle.font]).width)
    }

    /// The width the row needs to show its title and its whole value or shortcut.
    public var fittingWidth: CGFloat {
        var width = MenuMetrics.leading + size(of: entry.title) + MenuMetrics.trailing + chevronWidth
        if let text = rightText { width += MenuMetrics.valueGap + size(of: text) }
        return max(width, MenuMetrics.minimumWidth)
    }

    override public func draw(_ dirtyRect: NSRect) {
        let selected = isSelected
        if selected {
            let rect = bounds.insetBy(dx: MenuMetrics.highlightInset, dy: 0)
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: MenuMetrics.highlightRadius, yRadius: MenuMetrics.highlightRadius).fill()
        }
        let titleColor: NSColor = selected ? .selectedMenuItemTextColor
            : !entry.isEnabled ? .disabledControlTextColor : .labelColor
        let secondary: NSColor = selected ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.72)
            : entry.tone == .warning || entry.tone == .error ? MenuStyle.textColor(entry.tone) : .secondaryLabelColor

        let titleWidth = size(of: entry.title)
        let top = (bounds.height - MenuStyle.font.boundingRectForFont.height) / 2
        func draw(_ text: String, x: CGFloat, width: CGFloat, color: NSColor, alignment: NSTextAlignment) {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.alignment = alignment
            (text as NSString).draw(in: NSRect(x: x, y: top, width: width, height: MenuStyle.font.boundingRectForFont.height),
                                    withAttributes: [.font: MenuStyle.font, .foregroundColor: color, .paragraphStyle: style])
        }
        draw(entry.title, x: MenuMetrics.leading, width: titleWidth + 2, color: titleColor, alignment: .left)

        let right = bounds.width - MenuMetrics.trailing
        if entry.submenu != nil { drawChevron(endingAt: right, color: selected ? .selectedMenuItemTextColor : .secondaryLabelColor) }
        if let text = rightText {
            let end = right - chevronWidth
            let start = MenuMetrics.leading + titleWidth + MenuMetrics.valueGap
            let width = max(0, min(size(of: text), end - start))
            draw(text, x: end - width, width: width, color: secondary, alignment: .right)
        }
    }

    private func drawChevron(endingAt x: CGFloat, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: NSRect(x: x - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }

    // MARK: activation

    override public func mouseUp(with event: NSEvent) {
        // A submenu row opens on hover; only a row with an action ends the menu.
        guard entry.action != nil, entry.submenu == nil else { return }
        activate()
    }

    override public func accessibilityPerformPress() -> Bool {
        guard entry.action != nil else { return false }
        activate()
        return true
    }

    /// Closes the menu, then runs the item's action as a click on a plain item would.
    private func activate() {
        guard let item = enclosingMenuItem, item.isEnabled, let action = item.action else { return }
        item.menu?.cancelTracking()
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

/// The header block: the name and a one-line status in secondary grey at the left, the main switch at the right.
/// The switch is a custom view because a plain menu item cannot hold a control.
@MainActor
public final class MenuHeaderView: NSView {
    public let toggle = NSSwitch()
    /// The switch moved: true resumes Chirp, false pauses it.
    public var onToggle: ((Bool) -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")

    public init(header: MenuHeader) {
        super.init(frame: .zero)
        autoresizingMask = [.width]

        let title = NSTextField(labelWithString: header.title)
        title.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.textColor = .labelColor
        statusLabel.stringValue = header.status
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = MenuStyle.secondaryTextColor(header.tone)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [title, statusLabel] { label.setAccessibilityElement(false) }

        let stack = NSStackView(views: [title, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        toggle.state = header.isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel("Chirp")
        toggle.setAccessibilityHelp("Turns dictation on or off. Off releases the hotkey.")
        toggle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggle)

        let width = widthAnchor.constraint(greaterThanOrEqualToConstant: MenuMetrics.minimumWidth)
        NSLayoutConstraint.activate([
            width,
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.leading),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: stack.trailingAnchor, constant: 12),
            trailingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: MenuMetrics.trailing),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(header.accessibilityLabel)

        // Set the frame before any layout pass, so the autoresizing constraints are made from it, not from zero.
        setFrameSize(fittingSize)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    static let height: CGFloat = 44

    @objc private func toggled() { onToggle?(toggle.state == .on) }
}

/// The line between groups, inset like the system's.
@MainActor
public final class MenuSeparatorView: NSView {
    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.minimumWidth, height: MenuMetrics.separatorHeight))
        autoresizingMask = [.width]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override public var isFlipped: Bool { true }
    override public var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: MenuMetrics.separatorHeight) }

    override public func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: MenuMetrics.leading - 2, y: bounds.midY - 0.5, width: bounds.width - 2 * (MenuMetrics.leading - 2), height: 1).fill()
    }
}
