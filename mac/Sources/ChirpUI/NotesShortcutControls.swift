import AppKit
import ChirpCore

/// Settings controls for "Open Notes": its shortcut (shown, recorded, reset to ⌃⌥⇧N) and "Always show Chirp in the Dock".
@MainActor
public final class NotesShortcutControls {
    public let recorder = HotkeyRecorder()
    public let reset = NSButton(title: "Reset", target: nil, action: nil)
    public let alwaysInDock = NSButton(checkboxWithTitle: "Always show Chirp in the Dock", target: nil, action: nil)
    private let current = NSTextField(labelWithString: "")
    private let help = SettingsForm.help("")
    private var shown = KeyCombo.controlOptionShiftN

    public init() {
        current.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.setAccessibilityLabel("Reset the Open Notes shortcut")
        alwaysInDock.setAccessibilityLabel("Always show Chirp in the Dock")
        alwaysInDock.toolTip = "Off: Chirp is in the Dock and ⌘-Tab only while a Notes window is open."
        recorder.toolTip = "Brings the Notes window forward without recording. \(KeyCombo.controlOptionN.title) starts and stops."
        recorder.onStatusChange = { [weak self] _ in self?.refreshHelp() }
        refreshHelp()
    }

    /// The shortcut row: current keys, Record Shortcut…, Reset.
    public lazy var shortcutView: NSView = {
        let row = NSStackView(views: [current, recorder, reset])
        row.orientation = .horizontal
        row.spacing = 10
        let stack = NSStackView(views: [row, help])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }()

    public func show(_ combo: KeyCombo, alwaysInDock on: Bool) {
        shown = combo
        current.stringValue = combo.title
        reset.isEnabled = combo != .controlOptionShiftN
        alwaysInDock.state = on ? .on : .off
        refreshHelp()
    }

    private func refreshHelp() {
        help.textColor = .secondaryLabelColor
        help.isHidden = recorder.status == .idle   // the recorder's prompt or refusal only
        switch recorder.status {
        case .idle: break
        case .recording: help.stringValue = "Press the shortcut. Esc gives up."
        case .rejected(let why):
            help.stringValue = why.reason
            help.textColor = .systemRed
        }
    }
}
