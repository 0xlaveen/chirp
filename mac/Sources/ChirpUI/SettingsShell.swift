import AppKit

/// The Settings window's contents, laid out like System Settings: a sidebar (search field, one row per page with an icon,
/// About in the footer, a badge on General while a permission is missing) and the selected page's grouped form beside it.
/// The window is a fixed 720 × 520 and never resizes; a page taller than the window scrolls.
@MainActor
public final class SettingsShell: NSView, NSSearchFieldDelegate {
    public static let size = NSSize(width: 720, height: 520)
    static let sidebarWidth: CGFloat = 200

    public let form: SettingsForm
    public private(set) var selected: SettingsTab
    /// The user (or `select`) moved to a page.
    public var onSelect: ((SettingsTab) -> Void)?

    private let sidebar: NSView
    private let search = NSSearchField()
    private let list = NSStackView()
    private let empty = NSTextField(labelWithString: "No results")
    private var rows: [SettingsTab: SettingsSidebarRow] = [:]
    private let detail = NSView()
    private let scroll = NSScrollView()

    /// - Parameter flat: draws the sidebar as a plain Pond surface instead of the live `.sidebar` material (the offscreen snapshots
    ///   have no window to blur through).
    public init(form: SettingsForm, selected: SettingsTab = .general, flat: Bool = false) {
        self.form = form
        self.selected = selected
        if flat {
            let view = SettingsFlatView(SettingsLayout.sidebarBackground)
            sidebar = view
        } else {
            let effect = NSVisualEffectView()
            effect.material = .sidebar
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            sidebar = effect
        }
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        build()
        show(selected, notify: false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override public var isFlipped: Bool { true }
    /// The window's height; the snapshots raise it to show a whole page.
    public var contentHeight = SettingsShell.size.height
    override public var intrinsicContentSize: NSSize { NSSize(width: Self.size.width, height: contentHeight) }
    override public var fittingSize: NSSize { intrinsicContentSize }

    // MARK: layout

    private func build() {
        let page = SettingsFlatView(SettingsLayout.pageBackground)
        detail.translatesAutoresizingMaskIntoConstraints = false
        page.translatesAutoresizingMaskIntoConstraints = false
        addSubview(page)
        addSubview(sidebar)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(detail)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        detail.addSubview(scroll)

        search.placeholderString = "Search"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        search.setAccessibilityLabel("Search Settings")
        sidebar.addSubview(search)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(list)
        for tab in SettingsTab.sidebar { list.addArrangedSubview(makeRow(tab)) }

        empty.font = MenuStyle.font
        empty.textColor = .secondaryLabelColor
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(empty)

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(rule)
        let about = makeRow(.about)
        about.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(about)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            page.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.topAnchor.constraint(equalTo: topAnchor),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            detail.topAnchor.constraint(equalTo: page.topAnchor),
            detail.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            // Under the (transparent) title bar, whose height the traffic lights need.
            scroll.topAnchor.constraint(equalTo: detail.topAnchor, constant: 28),
            scroll.bottomAnchor.constraint(equalTo: detail.bottomAnchor),

            search.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 52),
            search.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            list.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            list.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            empty.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 20),
            empty.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),
            about.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            about.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            about.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -10),
            rule.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            rule.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            rule.bottomAnchor.constraint(equalTo: about.topAnchor, constant: -8),
        ])
        for row in list.arrangedSubviews { row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
    }

    private func makeRow(_ tab: SettingsTab) -> SettingsSidebarRow {
        let row = SettingsSidebarRow(tab: tab)
        row.onClick = { [weak self] in self?.show(tab) }
        rows[tab] = row
        return row
    }

    // MARK: selection

    /// Shows `tab`'s page and marks its row.
    public func show(_ tab: SettingsTab, notify: Bool = true) {
        selected = tab
        for (t, row) in rows { row.isSelected = t == tab }
        let page = form.view(for: tab)
        if scroll.documentView !== page {
            page.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = page
            let clip = scroll.contentView
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: clip.topAnchor),
                page.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            ])
            clip.scroll(to: .zero)
            scroll.reflectScrolledClipView(clip)
        }
        setAccessibilityLabel("Settings, \(tab.title)")
        if notify { onSelect?(tab) }
    }

    /// How many of the two permissions are missing: the number General's badge shows.
    public static func permissionProblems(micGranted: Bool, accessibilityGranted: Bool) -> Int {
        (micGranted ? 0 : 1) + (accessibilityGranted ? 0 : 1)
    }

    /// The red count on General: how many permissions are missing (0 hides it).
    public func setBadge(_ count: Int) { rows[.general]?.badge = count }

    // MARK: search

    /// The pages whose title or keywords contain `query` (all of them while it is empty).
    public static func pages(matching query: String) -> [SettingsTab] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SettingsTab.allCases }
        return SettingsTab.allCases.filter { tab in
            tab.title.lowercased().contains(q) || tab.keywords.contains { $0.contains(q) }
        }
    }

    /// Filters the sidebar; the open page follows to the first match when it no longer matches.
    public func setSearch(_ query: String) {
        if search.stringValue != query { search.stringValue = query }
        let matches = Self.pages(matching: query)
        for (tab, row) in rows { row.isHidden = !matches.contains(tab) }
        empty.isHidden = !matches.isEmpty
        if !matches.contains(selected), let first = matches.first { show(first) }
    }

    public func controlTextDidChange(_ obj: Notification) { setSearch(search.stringValue) }

    /// Esc in the field clears it.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), !search.stringValue.isEmpty else { return false }
        setSearch("")
        return true
    }
}

/// A view that fills itself with a Pond colour (re-resolved when the appearance changes).
@MainActor
final class SettingsFlatView: NSView {
    private let color: NSColor

    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
    }

    override var wantsUpdateLayer: Bool { true }
}

/// One sidebar row: an icon tile, the title, and (General) a badge. The selected row is a koi-tonal capsule.
@MainActor
final class SettingsSidebarRow: NSView {
    let tab: SettingsTab
    var onClick: (() -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { restyle() } } }
    var badge = 0 { didSet { if badge != oldValue { restyle() } } }

    private let tile = NSView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badgeView = NSTextField(labelWithString: "")

    init(tab: SettingsTab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        tile.wantsLayer = true
        tile.layer?.cornerRadius = 6
        tile.layer?.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
        tile.addSubview(icon)

        label.stringValue = tab.title
        label.font = MenuStyle.font
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        badgeView.font = .systemFont(ofSize: 11, weight: .semibold)
        badgeView.alignment = .center
        badgeView.textColor = .white
        badgeView.wantsLayer = true
        badgeView.drawsBackground = false
        badgeView.layer?.backgroundColor = MenuStyle.record.cgColor
        badgeView.layer?.cornerRadius = 8
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.isHidden = true
        addSubview(badgeView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 22),
            tile.heightAnchor.constraint(equalToConstant: 22),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeView.widthAnchor.constraint(equalToConstant: 16),
            badgeView.heightAnchor.constraint(equalToConstant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeView.leadingAnchor, constant: -4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        badgeView.isHidden = badge == 0
        badgeView.stringValue = "\(badge)"
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isSelected ? SettingsLayout.selection : .clear).cgColor
            tile.layer?.backgroundColor = (isSelected ? SettingsLayout.selectionTile : NSColor.labelColor.withAlphaComponent(0.1)).cgColor
            icon.contentTintColor = isSelected ? SettingsLayout.onSelectionTile : .secondaryLabelColor
            label.textColor = isSelected ? SettingsLayout.onSelection : .labelColor
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: isSelected ? .medium : .regular)
            badgeView.layer?.backgroundColor = MenuStyle.record.cgColor
        }
        setAccessibilityValue(isSelected ? 1 : 0)
        setAccessibilityLabel(badge > 0 ? "\(tab.title), \(badge) \(badge == 1 ? "permission needs" : "permissions need") attention" : tab.title)
    }
}
