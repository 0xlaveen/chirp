import AppKit
import ChirpCore

/// The Activity… sheet: the server's recent requests, newest first, as a table (Time · Device · What · Length · Result),
/// a device filter and the footer that says what is kept. The owner supplies the data through `apply`; the filter and
/// the table belong to the view. Rows read as one sentence to VoiceOver ("Pixel 8, Dictation, 4 seconds, OK, 10:14").
@MainActor
public final class DeviceActivityView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public static let size = NSSize(width: 640, height: 440)

    public let filter = NSPopUpButton(frame: .zero, pullsDown: false)
    public let doneButton = NSButton(title: "Done", target: nil, action: nil)
    public let table = NSTableView()
    private let scroll = NSScrollView()
    private let footer = SettingsForm.help("")
    private let empty = NSTextField(labelWithString: ActivityText.empty)
    private var activity: DeviceActivity?
    private var rows: [ActivityEvent] = []
    private var now = Date()
    private var locale = Locale.current
    private var timeZone = TimeZone.current
    /// The identity (`ActivityText.identity`) of the device the filter shows, nil for all.
    private var chosen: String?

    /// The rows now shown, newest first (after the filter).
    public var shownEvents: [ActivityEvent] { rows }
    public var onDone: (() -> Void)?

    public init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let heading = NSTextField(labelWithString: ActivityText.sheetTitle)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        filter.controlSize = .small
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.setAccessibilityLabel("Device")
        let top = NSStackView(views: [heading, NSView(), filter])
        top.orientation = .horizontal
        top.alignment = .centerY

        let widths: [CGFloat] = [84, 150, 110, 100, 100]
        for (i, title) in ActivityText.columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            column.title = title
            column.width = widths[i]
            column.minWidth = 60
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.style = .inset
        table.setAccessibilityLabel("Device activity")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.isHidden = true

        footer.maximumNumberOfLines = 4
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(done)
        let bottom = NSStackView(views: [footer, doneButton])
        bottom.orientation = .horizontal
        bottom.alignment = .bottom
        bottom.spacing = 12

        let stack = NSStackView(views: [top, scroll, empty, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    /// The sheet's own background, so the view reads the same offscreen.
    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    @objc private func done() { onDone?() }

    @objc private func filterChanged() {
        chosen = filter.selectedItem?.representedObject as? String
        reload()
    }

    /// Shows `activity`. The filter keeps its device while that device still has requests.
    public func apply(_ activity: DeviceActivity, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) {
        self.activity = activity
        self.now = now
        self.locale = locale
        self.timeZone = timeZone
        let choices = ActivityText.filterChoices(activity)
        if let chosen, !choices.contains(where: { ActivityText.identity($0) == chosen }) { self.chosen = nil }
        filter.removeAllItems()
        filter.addItem(withTitle: ActivityText.allDevices)
        for source in choices {
            filter.addItem(withTitle: ActivityText.sourceName(source))
            filter.lastItem?.representedObject = ActivityText.identity(source)
        }
        if let chosen, let index = filter.itemArray.firstIndex(where: { ($0.representedObject as? String) == chosen }) {
            filter.selectItem(at: index)
        } else {
            filter.selectItem(at: 0)
        }
        footer.stringValue = ActivityText.footer(activity, locale: locale, timeZone: timeZone)
        reload()
    }

    /// Picks the filter's device by identity (nil: all devices), as the pop-up does.
    public func select(deviceIdentity identity: String?) {
        chosen = identity
        if let index = filter.itemArray.firstIndex(where: { ($0.representedObject as? String) == identity }) {
            filter.selectItem(at: index)
        } else {
            filter.selectItem(at: 0)
        }
        reload()
    }

    private func reload() {
        let all = activity?.events ?? []
        rows = chosen.map { id in all.filter { ActivityText.identity($0.source) == id } } ?? all
        empty.isHidden = !rows.isEmpty
        scroll.isHidden = rows.isEmpty
        table.reloadData()
    }

    // MARK: table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, rows.indices.contains(row), let index = table.tableColumns.firstIndex(of: tableColumn) else { return nil }
        let event = rows[row]
        let text: String
        switch index {
        case 0: text = ActivityText.when(event.at, now: now, locale: locale, timeZone: timeZone)
        case 1: text = ActivityText.sourceName(event.source, client: event.client)
        case 2: text = ActivityText.kindName(event.kind)
        case 3: text = ActivityText.length(of: event)
        default: text = ActivityText.outcomeName(event.outcome)
        }
        let field = NSTextField(labelWithString: text)
        field.font = MenuStyle.secondaryFont
        field.lineBreakMode = .byTruncatingTail
        // A failure reads in orange; the row's spoken label carries the same words.
        if index == 4, event.outcome != .ok, event.outcome != .cancelled { field.textColor = .systemOrange }
        field.setAccessibilityElement(false)
        return field
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView()
        if rows.indices.contains(row) {
            view.setAccessibilityLabel(ActivityText.spoken(rows[row], now: now, locale: locale, timeZone: timeZone))
        }
        return view
    }
}
