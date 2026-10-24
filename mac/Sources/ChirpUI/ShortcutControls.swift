import AppKit
import ChirpCore

/// One row of Settings › Shortcuts for a shortcut other than dictation: its keys, Record Shortcut… and Reset (back to
/// the default). Under them, the recorder's prompt or refusal, else what the shortcut does.
@MainActor
public final class ShortcutControls {
    public let shortcut: ChirpShortcut
    public let recorder = HotkeyRecorder()
    public let reset = NSButton(title: "Reset", target: nil, action: nil)
    private let current = NSTextField(labelWithString: "")
    private let help = SettingsForm.help("")
    private let purpose: String

    public init(_ shortcut: ChirpShortcut, purpose: String) {
        self.shortcut = shortcut
        self.purpose = purpose
        current.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        current.lineBreakMode = .byTruncatingTail
        current.widthAnchor.constraint(equalToConstant: 64).isActive = true   // Record lines up from row to row
        current.setAccessibilityLabel("\(shortcut.owner) shortcut")
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.setAccessibilityLabel("Reset the \(shortcut.owner) shortcut")
        recorder.setAccessibilityLabel("Record a \(shortcut.owner) shortcut")
        recorder.onStatusChange = { [weak self] _ in self?.refreshHelp() }
        show(shortcut.defaultCombo)
    }

    /// The row: current keys, Record Shortcut…, Reset, and the help line under them.
    public lazy var view: NSView = {
        let row = NSStackView(views: [current, recorder, reset])
        row.orientation = .horizontal
        row.spacing = 10
        let stack = NSStackView(views: [row, help])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }()

    public var shownTitle: String { current.stringValue }
    public var helpText: String { help.stringValue }

    public func show(_ combo: KeyCombo) {
        current.stringValue = combo.title
        reset.isEnabled = !combo.sameKeys(shortcut.defaultCombo)
        refreshHelp()
    }

    /// Reset could not restore the default (another shortcut has it): says why until the next change.
    public func refuse(_ why: HotKeyValidation.Rejection) {
        help.stringValue = why.reason
        help.textColor = .systemRed
    }

    private func refreshHelp() {
        help.textColor = .secondaryLabelColor
        switch recorder.status {
        case .idle: help.stringValue = purpose
        case .recording: help.stringValue = "Press the shortcut. Esc gives up."
        case .rejected(let why):
            help.stringValue = why.reason
            help.textColor = .systemRed
        }
    }
}
