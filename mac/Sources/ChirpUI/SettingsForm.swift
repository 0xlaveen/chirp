import AppKit
import ChirpCore

/// What the Settings window shows. The window controller reads it from the system; the snapshots pass fixed values.
public struct SettingsState: Sendable {
    public var hotkey: KeyCombo = .controlOptionSpace
    public var serverURL = ServerConfig.defaultURL.absoluteString
    public var tokenPresent = true
    public var launch: LaunchState = .off
    public var soundsEnabled = false
    public var soundPack: SoundPack = .default
    /// 0…1.
    public var soundVolume = SoundTiming.defaultVolume
    /// The user's own files for the Custom pack, as imported.
    public var customStart: CustomSound?
    public var customStop: CustomSound?
    public var micGranted = true
    public var accessibilityGranted = true
    /// The server's state in words ("Connected", "Unreachable", …) and its tone.
    public var serverStatus = "Connected"
    public var serverStatusTone: MenuEntry.Tone = .ok
    /// Clean-up: the default style, the edited style prompts, the raw-first option and the per-app styles.
    public var cleanupStyle = CorrectionProfile.defaultID
    /// The prompts the user edited, by style id (only styles that differ from the server's default).
    public var stylePrompts: [String: String] = [:]
    /// The styles with their default prompts, and whether they are live, the last-known copy, or not loaded.
    public var catalog = StyleCatalog.unavailable
    /// The style the prompt editor opens on.
    public var editingStyle = CorrectionProfile.defaultID
    public var insertRawFirst = false
    /// "Show changes after clean-up": the diff highlight and the HUD's Use raw button. Off by default.
    public var showChanges = false
    public var appStyles = AppStyleRule.defaults
    /// The styles the server offers (the built-ins until it says otherwise) and whether it offers any at all.
    public var profiles = CorrectionProfile.builtIn
    public var serverOffersStyles = true

    public init() {}
}

/// The window's content view. It accepts first responder so the window can park focus here instead of on the Server
/// URL field, which would otherwise open selected.
public final class SettingsContentView: NSView {
    override public var acceptsFirstResponder: Bool { true }
}

/// The Settings window content, plain AppKit on purpose: the Command Line Tools toolchain has no SwiftUI macro
/// plugins (@State etc.). Labels sit right-aligned in one column and controls left-aligned in a second, under
/// General / Server / Permissions headings, with help text below its control. Controls are exposed so the owner can
/// attach targets and actions.
@MainActor
public final class SettingsForm {
    static let margin: CGFloat = 20
    static let controlWidth: CGFloat = 340

    /// The content view, with its 20 pt margin pinned by constraints so `fittingSize` includes it on every side.
    public let view = SettingsContentView()
    public let hotkey = NSPopUpButton(frame: .zero, pullsDown: false)
    public let recorder = HotkeyRecorder()
    /// Under the hotkey: how it works, or why the last recording was refused.
    public let hotkeyHelp = SettingsForm.help("")
    public let sounds = NSButton(checkboxWithTitle: "Play start and stop sounds", target: nil, action: nil)
    /// Sounds: the pack, ▶ previews, the volume, and (for the Custom pack) the user's files.
    public let soundPack = NSPopUpButton(frame: .zero, pullsDown: false)
    public let previewStart = NSButton(title: "▶ Start", target: nil, action: nil)
    public let previewStop = NSButton(title: "▶ Stop", target: nil, action: nil)
    public let volume = NSSlider(value: SoundTiming.defaultVolume * 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    public let chooseStart = NSButton(title: "Choose…", target: nil, action: nil)
    public let removeStart = NSButton(title: "Remove", target: nil, action: nil)
    public let chooseStop = NSButton(title: "Choose…", target: nil, action: nil)
    public let removeStop = NSButton(title: "Remove", target: nil, action: nil)
    /// Under the start file: the 0.3 s rule, or why the last import failed.
    public let customStartHelp = SettingsForm.help("")
    private let packHelp = SettingsForm.help("")
    private let volumeLabel = NSTextField(labelWithString: "")
    private let startFile = NSTextField(labelWithString: "")
    private let stopFile = NSTextField(labelWithString: "")
    private var customStartSound: CustomSound?
    private var customStopSound: CustomSound?
    private var soundError: String?
    private var customRows: [Int] = []
    private var grid = NSGridView()
    public let serverURL = NSTextField(string: "")
    public let launch = NSButton(checkboxWithTitle: "Launch Chirp at login", target: nil, action: nil)
    public let micButton = NSButton(title: "Fix…", target: nil, action: nil)
    public let accessibilityButton = NSButton(title: "Fix…", target: nil, action: nil)
    /// Under the checkbox: what it does, or why the last change failed.
    public let launchHelp = SettingsForm.help("")
    /// Clean-up: default style, style prompts, raw-first and the per-app table.
    public let style = NSPopUpButton(frame: .zero, pullsDown: false)
    public let prompts = StylePromptsEditor()
    public let insertRawFirst = NSButton(checkboxWithTitle: "Insert raw immediately, then replace with cleaned", target: nil, action: nil)
    public let showChanges = NSButton(checkboxWithTitle: "Show changes after clean-up", target: nil, action: nil)
    public let appStyles = AppStylesTable()
    private let styleHelp = SettingsForm.help("")
    private var shownProfileIDs: [String] = []
    private var shownCatalog: StyleCatalog?
    private let tokenStatus = StatusLine()
    private let tokenHelp = SettingsForm.help("")
    private let serverStatus = StatusLine()
    private let micStatus = StatusLine()
    private let accessibilityStatus = StatusLine()
    private var launchUnavailable = false

    public init(_ state: SettingsState) {
        recorder.onStatusChange = { [weak self] _ in self?.refreshHotkeyHelp() }
        serverURL.placeholderString = ServerConfig.defaultURL.absoluteString
        serverURL.font = MenuStyle.font
        serverURL.lineBreakMode = .byTruncatingMiddle
        serverURL.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        for button in [micButton, accessibilityButton] { button.bezelStyle = .rounded; button.controlSize = .small }
        micStatus.accessory = micButton
        accessibilityStatus.accessory = accessibilityButton
        micButton.setAccessibilityLabel("Fix Microphone access")
        accessibilityButton.setAccessibilityLabel("Fix Accessibility access")

        var rows: [[NSView]] = []
        var headings: [Int] = []
        func section(_ title: String) {
            headings.append(rows.count)
            rows.append([Self.heading(title), NSGridCell.emptyContentView])
        }
        func row(_ title: String, _ control: NSView, help: NSTextField? = nil) {
            var content = control
            if let help {
                let stack = NSStackView(views: [control, help])
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 4
                content = stack
            }
            rows.append([Self.label(title), content])
        }

        section("General")
        let hotkeyRow = NSStackView(views: [hotkey, recorder])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 10
        row("Hotkey:", hotkeyRow, help: hotkeyHelp)
        row("Startup:", launch, help: launchHelp)
        section("Sounds")
        row("Cues:", sounds, help: Self.help("Quiet sounds when dictation starts and stops. Off keeps Chirp silent."))
        let packRow = NSStackView(views: [soundPack, previewStart, previewStop])
        packRow.orientation = .horizontal
        packRow.spacing = 8
        row("Pack:", packRow, help: packHelp)
        let volumeRow = NSStackView(views: [volume, volumeLabel])
        volumeRow.orientation = .horizontal
        volumeRow.spacing = 8
        row("Volume:", volumeRow)
        customRows.append(rows.count)
        row("Start sound:", Self.fileRow(startFile, choose: chooseStart, remove: removeStart), help: customStartHelp)
        customRows.append(rows.count)
        row("Stop sound:", Self.fileRow(stopFile, choose: chooseStop, remove: removeStop),
            help: Self.help("Plays after you stop talking, up to \(SoundTiming.stopLimit) s."))
        section("Clean-up")
        row("Style:", style, help: styleHelp)
        row("Prompts:", prompts.view)
        row("Per-app:", appStyles.view, help: Self.help("The frontmost app when you start dictating picks the style. Other apps use the default style."))
        row("Insertion:", insertRawFirst, help: Self.help("Swaps in the cleaned text in place where Chirp can verify the insert; elsewhere it inserts once."))
        row("Review:", showChanges, help: Self.help("Off: the cleaned text is inserted at once and the HUD fades away; “Use raw” stays on for 5 seconds with ⌃⌥Z or in the menu. On: the HUD highlights what changed and keeps a Use raw button."))
        section("Server")
        row("URL:", serverURL)
        row("Token:", tokenStatus, help: tokenHelp)
        row("Status:", serverStatus)
        section("Permissions")
        row("Microphone:", micStatus, help: Self.help("Lets Chirp hear you."))
        row("Accessibility:", accessibilityStatus, help: Self.help("Lets Chirp insert text into other apps and send ⌘V."))

        grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        for (n, index) in headings.enumerated() {
            let r = grid.row(at: index)
            r.mergeCells(in: NSRange(location: 0, length: 2))
            r.cell(at: 0).xPlacement = .leading
            r.rowAlignment = .none
            if n > 0 { r.topPadding = 14 }
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.margin),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.margin),
            view.bottomAnchor.constraint(equalTo: grid.bottomAnchor, constant: Self.margin),
            view.trailingAnchor.constraint(equalTo: grid.trailingAnchor, constant: Self.margin),
        ])
        refreshHotkeyHelp()
        configureSoundControls()
        apply(state, full: true)
    }

    private func configureSoundControls() {
        for pack in SoundPack.allCases {
            soundPack.addItem(withTitle: pack.title)
            soundPack.lastItem?.representedObject = pack.rawValue
        }
        for b in [previewStart, previewStop, chooseStart, removeStart, chooseStop, removeStop] {
            b.bezelStyle = .rounded
            b.controlSize = .small
        }
        previewStart.setAccessibilityLabel("Preview the start sound")
        previewStop.setAccessibilityLabel("Preview the stop sound")
        chooseStart.setAccessibilityLabel("Choose a start sound file")
        chooseStop.setAccessibilityLabel("Choose a stop sound file")
        removeStart.setAccessibilityLabel("Remove the custom start sound")
        removeStop.setAccessibilityLabel("Remove the custom stop sound")
        soundPack.setAccessibilityLabel("Sound pack")
        volume.isContinuous = true
        volume.setAccessibilityLabel("Volume")
        volume.widthAnchor.constraint(equalToConstant: 200).isActive = true
        volumeLabel.font = MenuStyle.font
        volumeLabel.alignment = .right
        volumeLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        for f in [startFile, stopFile] {
            f.font = MenuStyle.font
            f.lineBreakMode = .byTruncatingMiddle
            f.widthAnchor.constraint(equalToConstant: 170).isActive = true
        }
    }

    /// The label under the slider follows it live.
    public func setVolume(_ fraction: Double) {
        volume.doubleValue = fraction * 100
        volumeLabel.stringValue = "\(SoundTiming.percent(volume: fraction))%"
    }

    /// The Custom rows show only for the Custom pack.
    public func showPack(_ pack: SoundPack) {
        if let i = soundPack.itemArray.firstIndex(where: { $0.representedObject as? String == pack.rawValue }) { soundPack.selectItem(at: i) }
        packHelp.stringValue = pack.detail
        for index in customRows { grid.row(at: index).isHidden = pack != .custom }
    }

    /// Shows the imported files (name and length) and the trimming warning; `error` replaces the warning once.
    public func setCustomSounds(start: CustomSound?, stop: CustomSound?, error: String? = nil) {
        customStartSound = start
        customStopSound = stop
        soundError = error
        startFile.stringValue = start.map { "\($0.displayName) · \(SoundTiming.durationText($0.duration))" } ?? "None (uses Chirp)"
        stopFile.stringValue = stop.map { "\($0.displayName) · \(SoundTiming.durationText($0.duration))" } ?? "None (uses Chirp)"
        startFile.textColor = start == nil ? .secondaryLabelColor : .labelColor
        stopFile.textColor = stop == nil ? .secondaryLabelColor : .labelColor
        removeStart.isEnabled = start != nil
        removeStop.isEnabled = stop != nil
        if let error {
            customStartHelp.stringValue = error
            customStartHelp.textColor = .systemRed
        } else if let start, SoundTiming.isTrimmed(.start, duration: start.duration) {
            customStartHelp.stringValue = "\(SoundTiming.longStartWarning) Yours is \(SoundTiming.durationText(start.duration))."
            customStartHelp.textColor = MenuStyle.textColor(.warning)
        } else {
            customStartHelp.stringValue = SoundTiming.longStartWarning
            customStartHelp.textColor = .secondaryLabelColor
        }
    }

    /// Puts the form in `window`, sized to fit, with focus parked on the content view so no field opens selected.
    public func install(in window: NSWindow) {
        let size = view.fittingSize
        // The form is tall now: on a small screen it scrolls instead of running off it.
        let limit = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let cap = max(480, limit - 90)
        if size.height > cap {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.documentView = view
            window.contentView = scroll
            window.setContentSize(NSSize(width: size.width + 16, height: cap))
        } else {
            window.contentView = view
            window.setContentSize(size)
        }
        window.initialFirstResponder = view
        window.makeFirstResponder(view)
    }

    /// Fills the window. The periodic refresh passes `full: false` so it only follows the server and permission
    /// states and never overwrites what the user is typing or a login-item error shown under the checkbox.
    public func apply(_ s: SettingsState, full: Bool = false) {
        if full {
            fillHotkeyMenu(selecting: s.hotkey)
            sounds.state = s.soundsEnabled ? .on : .off
            showPack(s.soundPack)
            setVolume(s.soundVolume)
            setCustomSounds(start: s.customStart, stop: s.customStop)
            serverURL.stringValue = s.serverURL
            launch.state = s.launch == .on ? .on : .off
            launch.isEnabled = s.launch != .unavailable
            launchUnavailable = s.launch == .unavailable
            setLaunchError(nil)
            style.controlSize = .regular
            fillStyleMenu(s.profiles, selecting: s.cleanupStyle, offered: s.serverOffersStyles)
            prompts.configure(catalog: s.catalog, overrides: s.stylePrompts, selecting: s.editingStyle)
            shownCatalog = s.catalog
            insertRawFirst.state = s.insertRawFirst ? .on : .off
            showChanges.state = s.showChanges ? .on : .off
            appStyles.setProfiles(s.profiles)
            appStyles.setRules(s.appStyles)
        } else if s.profiles.map(\.id) != shownProfileIDs {
            // The server's style list arrived after the window opened: follow it without touching what is being edited.
            let current = style.selectedItem?.representedObject as? String ?? s.cleanupStyle
            fillStyleMenu(s.profiles, selecting: current, offered: s.serverOffersStyles)
            appStyles.setProfiles(s.profiles)
        }
        if !full, s.catalog != shownCatalog {
            // The server's prompts arrived (or it went away) after the window opened. Edits are saved as they are
            // made, so reloading from the saved ones loses nothing.
            prompts.configure(catalog: s.catalog, overrides: s.stylePrompts)
            shownCatalog = s.catalog
        }
        tokenStatus.set(symbol: s.tokenPresent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tone: s.tokenPresent ? .ok : .warning, text: "~/.config/chirp/token")
        tokenHelp.stringValue = s.tokenPresent ? "Chirp sends this token with every request."
                                               : "No token yet — start chirp-server once to create it."
        serverStatus.set(symbol: "circle.fill", tone: s.serverStatusTone, text: s.serverStatus)
        micStatus.set(symbol: s.micGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                      tone: s.micGranted ? .ok : .warning, text: s.micGranted ? "Allowed" : "Not allowed")
        accessibilityStatus.set(symbol: s.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                tone: s.accessibilityGranted ? .ok : .warning, text: s.accessibilityGranted ? "Allowed" : "Not allowed")
        micButton.isHidden = s.micGranted
        accessibilityButton.isHidden = s.accessibilityGranted
    }

    /// The presets, plus the recorded shortcut when one is in use, with `current` selected.
    public func fillHotkeyMenu(selecting current: KeyCombo) {
        hotkey.removeAllItems()
        for combo in KeyCombo.presets + (current.isCustom ? [current] : []) {
            hotkey.addItem(withTitle: combo.isCustom ? "\(combo.title) (custom)" : combo.title)
            hotkey.lastItem?.representedObject = combo.id
        }
        if let index = hotkey.itemArray.firstIndex(where: { $0.representedObject as? String == current.id }) {
            hotkey.selectItem(at: index)
        }
    }

    /// The styles, with `current` selected (an id the server no longer lists stays selectable, so it is not silently changed).
    public func fillStyleMenu(_ profiles: [CorrectionProfile], selecting current: String, offered: Bool = true) {
        var list = profiles
        if !list.contains(where: { $0.id == current }) {
            list.append(CorrectionProfile(id: current, name: CorrectionProfile.displayName(for: current)))
        }
        shownProfileIDs = profiles.map(\.id)
        style.removeAllItems()
        for p in list {
            style.addItem(withTitle: p.name)
            style.lastItem?.representedObject = p.id
            style.lastItem?.toolTip = p.description
        }
        if let i = list.firstIndex(where: { $0.id == current }) { style.selectItem(at: i) }
        let chosen = list.first { $0.id == current }
        var text = chosen?.description ?? ""
        if chosen?.rewrites == true { text += (text.isEmpty ? "" : " ") + "May restructure your text." }
        if !offered { text = "This server does not offer styles yet; update chirp-server to use them." }
        styleHelp.stringValue = text
    }

    private func refreshHotkeyHelp() {
        hotkeyHelp.textColor = .secondaryLabelColor
        switch recorder.status {
        case .idle: hotkeyHelp.stringValue = "Tap to start/stop. Hold to talk, release to finish. Esc cancels."
        case .recording: hotkeyHelp.stringValue = "Press the shortcut you want. Esc gives up."
        case .rejected(let why):
            hotkeyHelp.stringValue = why.reason
            hotkeyHelp.textColor = .systemRed
        }
    }

    /// Shows why toggling launch at login failed under the checkbox; nil restores the usual help text.
    public func setLaunchError(_ message: String?) {
        if let message {
            launchHelp.stringValue = "Couldn’t change it: \(message)"
            launchHelp.textColor = .systemRed
        } else {
            launchHelp.stringValue = launchUnavailable ? "Available when Chirp runs from its app bundle."
                                                       : "Opens Chirp when you log in."
            launchHelp.textColor = .secondaryLabelColor
        }
    }

    // MARK: pieces

    /// A file's name and length, then Choose… and Remove.
    private static func fileRow(_ name: NSTextField, choose: NSButton, remove: NSButton) -> NSView {
        let stack = NSStackView(views: [name, choose, remove])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private static func label(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = MenuStyle.font
        f.alignment = .right
        return f
    }

    private static func heading(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = MenuStyle.semiboldFont
        return f
    }

    /// Secondary-colour help text under a control, wrapped to the control column's width.
    static func help(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = MenuStyle.secondaryFont
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = controlWidth
        return f
    }
}

/// A status symbol, a label and an optional trailing button (hidden when it has nothing to fix).
@MainActor
private final class StatusLine: NSStackView {
    private let icon = NSImageView()
    private let text = NSTextField(labelWithString: "")
    var accessory: NSView? { didSet { if let accessory { addArrangedSubview(accessory) } } }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        text.font = MenuStyle.font
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.setAccessibilityElement(false)
        addArrangedSubview(icon)
        addArrangedSubview(text)
        setCustomSpacing(10, after: text)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    func set(symbol: String, tone: MenuEntry.Tone, text string: String) {
        icon.image = MenuStyle.symbol(symbol, tone: tone)
        text.stringValue = string
    }
}
