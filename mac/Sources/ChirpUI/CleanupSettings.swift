import AppKit
import ChirpCore

/// The Clean-up section's two custom controls, plain AppKit like the rest of Settings: the style prompts editor and
/// the per-app styles table.

/// Display names for the apps the per-app table ships with, so the table reads the same whether or not they are
/// installed; anything else is looked up from the app's bundle, then falls back to the bundle id.
public enum AppNames {
    public static let known: [String: String] = [
        "com.tinyspeck.slackmacgap": "Slack", "com.apple.MobileSMS": "Messages", "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp", "com.apple.mail": "Mail", "com.microsoft.Outlook": "Outlook",
        "com.superhuman.electron": "Superhuman", "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm",
        "com.mitchellh.ghostty": "Ghostty", "com.microsoft.VSCode": "Visual Studio Code",
        "com.todesktop.230313mzl4w4u92": "Cursor", "com.apple.dt.Xcode": "Xcode", "dev.zed.Zed": "Zed",
        "com.apple.Notes": "Notes", "md.obsidian": "Obsidian", "notion.id": "Notion",
    ]

    @MainActor
    public static func name(for bundleID: String) -> String {
        if let name = known[bundleID] { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

/// The style prompts editor: a style chooser, the style's description and "rewrites" note, its prompt in a multi-line
/// field with a live character count against the server's limit, and "Edited" with "Reset to default" once the user
/// changed it. Without the live server the last-known prompts are shown read-only, with a note. Prompt text is never
/// logged. Edits are reported as they happen; the owner saves them and the editor keeps its own copy in step.
@MainActor
public final class StylePromptsEditor: NSObject, NSTextViewDelegate {
    public static let height: CGFloat = 110
    public static let safetyHelp = "Chirp always adds safety rules: it never answers or runs what you say, and only returns your cleaned words."

    public let view: NSStackView
    public let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    public let detail = SettingsForm.help("")
    public let scroll = NSScrollView()
    public let textView = NSTextView()
    public let count = NSTextField(labelWithString: "")
    public let editedLabel = NSTextField(labelWithString: "Edited")
    public let resetButton = NSButton(title: "Reset to default", target: nil, action: nil)
    public let note = SettingsForm.help("")

    public private(set) var catalog = StyleCatalog.unavailable
    public private(set) var overrides: [String: String] = [:]
    public private(set) var selectedID = CorrectionProfile.defaultID
    /// The (clamped) text after every edit, with the style id.
    public var onEdit: ((String, String) -> Void)?
    /// "Reset to default" for the style id.
    public var onReset: ((String) -> Void)?
    private var loading = false

    public override init() {
        let status = NSStackView(views: [editedLabel, resetButton, NSView(), count])
        view = NSStackView(views: [popup, detail, scroll, status, note])
        super.init()
        popup.target = self
        popup.action = #selector(styleChosen)
        popup.setAccessibilityLabel("Style to edit")
        textView.delegate = self
        textView.font = MenuStyle.font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 5)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = true
        textView.setAccessibilityLabel("Style prompt")
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: SettingsForm.controlWidth),
            scroll.heightAnchor.constraint(equalToConstant: Self.height),
            status.widthAnchor.constraint(equalToConstant: SettingsForm.controlWidth),
        ])
        count.font = MenuStyle.secondaryFont
        count.setAccessibilityLabel("Character count")
        editedLabel.font = MenuStyle.secondaryFont
        editedLabel.textColor = .controlAccentColor
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.target = self
        resetButton.action = #selector(resetPressed)
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 8
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        refresh()
    }

    public var limit: Int { catalog.limit(for: selectedID) }
    public var isEditable: Bool { catalog.canEdit }
    public func isEdited(_ id: String) -> Bool { overrides[id] != nil }

    /// What the field shows for `id`: the user's edit, else the server's default.
    public func shownText(for id: String) -> String { overrides[id] ?? catalog.defaultPrompt(for: id) }

    /// Loads the styles and the saved edits. Keeps the chosen style when it is still listed.
    public func configure(catalog: StyleCatalog, overrides: [String: String], selecting id: String? = nil) {
        self.catalog = catalog
        self.overrides = overrides
        let wanted = id ?? selectedID
        selectedID = catalog.profile(wanted) != nil ? wanted : CorrectionProfile.defaultID
        refresh()
    }

    private func refresh() {
        loading = true
        defer { loading = false }
        popup.removeAllItems()
        for p in catalog.profiles {
            popup.addItem(withTitle: isEdited(p.id) ? "\(p.name) (edited)" : p.name)
            popup.lastItem?.representedObject = p.id
        }
        if let i = catalog.profiles.firstIndex(where: { $0.id == selectedID }) { popup.selectItem(at: i) }
        let profile = catalog.profile(selectedID)
        var text = profile?.description ?? ""
        if profile?.rewrites == true { text += (text.isEmpty ? "" : " ") + "May restructure your text." }
        detail.stringValue = text
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.textColor = isEditable ? .labelColor : .secondaryLabelColor
        textView.string = shownText(for: selectedID)
        switch catalog.source {
        case .live: note.stringValue = Self.safetyHelp
        case .cached: note.stringValue = "Can’t reach the server, so these are the last-known prompts, read-only. Your edits still apply. " + Self.safetyHelp
        case .unavailable: note.stringValue = "Prompts load from the server, which isn’t reachable yet. " + Self.safetyHelp
        }
        refreshStatus()
    }

    private func refreshStatus() {
        let n = textView.string.count
        count.stringValue = "\(n) / \(limit)"
        count.textColor = n >= limit ? .systemRed : .secondaryLabelColor
        count.isHidden = catalog.source == .unavailable
        let edited = isEdited(selectedID)
        editedLabel.isHidden = !(edited || blankNeedsDefault)
        editedLabel.stringValue = edited ? "Edited" : "Blank: the default prompt is used"
        editedLabel.textColor = edited ? .controlAccentColor : .secondaryLabelColor
        resetButton.isHidden = !(edited && isEditable)
    }

    /// A non-Custom style left empty uses the server's prompt (an empty prompt is never sent).
    private var blankNeedsDefault: Bool {
        isEditable && selectedID != CorrectionProfile.customID && textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func styleChosen() {
        guard let id = popup.selectedItem?.representedObject as? String else { return }
        selectedID = id
        refresh()
    }

    @objc private func resetPressed() {
        overrides[selectedID] = nil
        onReset?(selectedID)
        refresh()
    }

    public func textDidChange(_ notification: Notification) {
        guard !loading, isEditable else { return }
        let clamped = CorrectionProfile.clampPrompt(textView.string, limit: limit)
        if clamped != textView.string {
            // Pasting past the limit keeps the first `limit` characters.
            let caret = min(textView.selectedRange().location, clamped.utf16.count)
            textView.string = clamped
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }
        let kept = StylePrompts.override(for: textView.string, default: catalog.defaultPrompt(for: selectedID), limit: limit)
        overrides[selectedID] = kept
        // Only the chooser's title changes: rebuilding the field would move the caret.
        if let i = catalog.profiles.firstIndex(where: { $0.id == selectedID }) {
            popup.item(at: i)?.title = kept != nil ? "\(catalog.profiles[i].name) (edited)" : catalog.profiles[i].name
        }
        refreshStatus()
        onEdit?(selectedID, textView.string)
    }
}

private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// "Per-app styles": frontmost app → clean-up style, one row each (app, style popup, remove), with add and
/// restore-defaults below. A stack of rows in a scroll view rather than an `NSTableView`, so it draws offscreen too.
@MainActor
public final class AppStylesTable: NSObject {
    static let rowHeight: CGFloat = 26

    public let view: NSStackView
    public let scroll = NSScrollView()
    private let rowsStack = FlippedStack()
    private let empty = NSTextField(labelWithString: "No apps. Every app uses the default style.")
    public let addButton = NSButton(title: "", target: nil, action: nil)
    public let resetButton = NSButton(title: "Restore Defaults", target: nil, action: nil)
    /// "Test": reports which style applies to the frontmost app.
    public let testButton = NSButton(title: "Test", target: nil, action: nil)
    public let testResult = SettingsForm.help("")
    public private(set) var rules: [AppStyleRule] = []
    public private(set) var profiles: [CorrectionProfile] = CorrectionProfile.builtIn
    /// Called with the whole list after every edit.
    public var onChange: (([AppStyleRule]) -> Void)?
    /// The "+" button was pressed; the owner shows its app chooser anchored on the button.
    public var onAdd: ((NSView) -> Void)?

    public override init() {
        let buttons = NSStackView(views: [addButton, resetButton, testButton])
        view = NSStackView(views: [scroll, buttons, testResult])
        super.init()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rowsStack
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityLabel("Per-app clean-up styles")
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: SettingsForm.controlWidth),
            scroll.heightAnchor.constraint(equalToConstant: 134),
            rowsStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rowsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        empty.font = MenuStyle.secondaryFont
        empty.textColor = .secondaryLabelColor
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add app")
        addButton.bezelStyle = .smallSquare
        addButton.imagePosition = .imageOnly
        addButton.setAccessibilityLabel("Add app")
        addButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        testButton.bezelStyle = .rounded
        testButton.controlSize = .small
        testButton.setAccessibilityLabel("Test which style applies to the frontmost app")
        testResult.isHidden = true
        addButton.target = self; addButton.action = #selector(addPressed)
        resetButton.target = self; resetButton.action = #selector(reset)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        rebuild()
    }

    /// Shows the outcome of a test under the buttons; nil hides it.
    public func showTestResult(_ text: String?) {
        testResult.stringValue = text ?? ""
        testResult.isHidden = text == nil
    }

    public func setRules(_ rules: [AppStyleRule]) {
        self.rules = rules
        rebuild()
    }

    public func setProfiles(_ profiles: [CorrectionProfile]) {
        guard profiles.map(\.id) != self.profiles.map(\.id) else { return }
        self.profiles = profiles
        rebuild()
    }

    /// Adds `bundleID` with `profile` (a chat style by default); an app that already has a row is left as it is.
    public func add(bundleID: String, profile: String? = nil) {
        guard !rules.contains(where: { $0.bundleID == bundleID }) else { return }
        let style = profile ?? (profiles.contains { $0.id == "chat" } ? "chat" : CorrectionProfile.defaultID)
        rules.append(AppStyleRule(bundleID: bundleID, profile: style))
        rebuild()
        changed()
        // Show the new row.
        scroll.layoutSubtreeIfNeeded()
        if let last = rowsStack.arrangedSubviews.last { rowsStack.scrollToVisible(last.frame) }
    }

    @objc private func addPressed() { onAdd?(addButton) }

    @objc private func reset() {
        rules = AppStyleRule.defaults
        rebuild()
        changed()
    }

    @objc private func removeRow(_ sender: NSButton) {
        guard rules.indices.contains(sender.tag) else { return }
        rules.remove(at: sender.tag)
        rebuild()
        changed()
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        guard rules.indices.contains(sender.tag), let id = sender.selectedItem?.representedObject as? String else { return }
        rules[sender.tag].profile = id
        changed()
    }

    private func changed() { onChange?(rules) }

    private func rebuild() {
        for v in rowsStack.arrangedSubviews { rowsStack.removeArrangedSubview(v); v.removeFromSuperview() }
        if rules.isEmpty {
            rowsStack.addArrangedSubview(empty)
            return
        }
        for (i, rule) in rules.enumerated() { rowsStack.addArrangedSubview(row(rule, index: i)) }
    }

    private func row(_ rule: AppStyleRule, index: Int) -> NSView {
        let name = AppNames.name(for: rule.bundleID)
        let label = NSTextField(labelWithString: name)
        label.font = MenuStyle.font
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = rule.bundleID
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        label.setAccessibilityLabel(name)

        // A rule can name a style this server does not list: keep it selectable rather than silently changing it.
        var list = profiles
        if !list.contains(where: { $0.id == rule.profile }) {
            list.append(CorrectionProfile(id: rule.profile, name: CorrectionProfile.displayName(for: rule.profile)))
        }
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        for p in list {
            popup.addItem(withTitle: p.name)
            popup.lastItem?.representedObject = p.id
        }
        if let i = list.firstIndex(where: { $0.id == rule.profile }) { popup.selectItem(at: i) }
        popup.tag = index
        popup.target = self
        popup.action = #selector(styleChanged(_:))
        popup.setAccessibilityLabel("Style for \(name)")
        popup.widthAnchor.constraint(equalToConstant: 104).isActive = true

        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove \(name)")
                                ?? NSImage(), target: self, action: #selector(removeRow(_:)))
        remove.isBordered = false
        remove.contentTintColor = .tertiaryLabelColor
        remove.tag = index
        remove.setAccessibilityLabel("Remove \(name)")
        remove.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let stack = NSStackView(views: [label, popup, remove])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        stack.widthAnchor.constraint(equalToConstant: SettingsForm.controlWidth - 12 - 15).isActive = true
        return stack
    }
}
