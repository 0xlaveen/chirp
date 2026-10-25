import AppKit
import ChirpCore

/// One row of Settings › Dictation › Shortcuts for a shortcut other than dictation: its keys, Record Shortcut… and Reset
/// (back to the default), with the recorder's prompt or refusal, else what the shortcut does, as its help line.
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
        current.alignment = .right
        current.widthAnchor.constraint(equalToConstant: 64).isActive = true   // Record lines up from row to row
        current.setAccessibilityLabel("\(shortcut.owner) shortcut")
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.setAccessibilityLabel("Reset the \(shortcut.owner) shortcut")
        recorder.setAccessibilityLabel("Record a \(shortcut.owner) shortcut")
        recorder.onStatusChange = { [weak self] _ in self?.refreshHelp() }
        show(shortcut.defaultCombo)
    }

    /// The keys, Record Shortcut… and Reset in one line; the help line is `helpView`, under the row's title.
    public lazy var view: NSView = {
        let row = NSStackView(views: [current, recorder, reset])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }()

    /// The recorder's prompt or refusal, else what the shortcut does.
    public var helpView: NSTextField { help }

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
