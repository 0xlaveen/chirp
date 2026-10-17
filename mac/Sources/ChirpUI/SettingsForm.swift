import AppKit
import ChirpCore

/// What the Settings window shows. The window controller reads it from the system; the snapshots pass fixed values.
public struct SettingsState: Sendable {
    public var hotkey: KeyCombo = .controlOptionSpace
    public var serverURL = ServerConfig.defaultURL.absoluteString
    public var tokenPresent = true
    public var launch: LaunchState = .off
    public var micGranted = true
    public var accessibilityGranted = true
    /// The server's state in words ("Connected", "Unreachable", …) and its tone.
    public var serverStatus = "Connected"
    public var serverStatusTone: MenuEntry.Tone = .ok

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
    public let serverURL = NSTextField(string: "")
    public let launch = NSButton(checkboxWithTitle: "Launch Chirp at login", target: nil, action: nil)
    public let micButton = NSButton(title: "Fix…", target: nil, action: nil)
    public let accessibilityButton = NSButton(title: "Fix…", target: nil, action: nil)
    /// Under the checkbox: what it does, or why the last change failed.
    public let launchHelp = SettingsForm.help("")
    private let tokenStatus = StatusLine()
    private let tokenHelp = SettingsForm.help("")
    private let serverStatus = StatusLine()
    private let micStatus = StatusLine()
    private let accessibilityStatus = StatusLine()
    private var launchUnavailable = false

    public init(_ state: SettingsState) {
        for combo in KeyCombo.presets {
            hotkey.addItem(withTitle: combo.title)
            hotkey.lastItem?.representedObject = combo.id
        }
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
        row("Hotkey:", hotkey, help: Self.help("Tap to start/stop. Hold to talk, release to finish. Esc cancels."))
        row("Startup:", launch, help: launchHelp)
        section("Server")
        row("URL:", serverURL)
        row("Token:", tokenStatus, help: tokenHelp)
        row("Status:", serverStatus)
        section("Permissions")
        row("Microphone:", micStatus, help: Self.help("Lets Chirp hear you."))
        row("Accessibility:", accessibilityStatus, help: Self.help("Lets Chirp insert text into other apps and send ⌘V."))

        let grid = NSGridView(views: rows)
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
        apply(state, full: true)
    }

    /// Puts the form in `window`, sized to fit, with focus parked on the content view so no field opens selected.
    public func install(in window: NSWindow) {
        window.contentView = view
        window.setContentSize(view.fittingSize)
        window.initialFirstResponder = view
        window.makeFirstResponder(view)
    }

    /// Fills the window. The periodic refresh passes `full: false` so it only follows the server and permission
    /// states and never overwrites what the user is typing or a login-item error shown under the checkbox.
    public func apply(_ s: SettingsState, full: Bool = false) {
        if full {
            hotkey.selectItem(withTitle: s.hotkey.title)
            serverURL.stringValue = s.serverURL
            launch.state = s.launch == .on ? .on : .off
            launch.isEnabled = s.launch != .unavailable
            launchUnavailable = s.launch == .unavailable
            setLaunchError(nil)
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
