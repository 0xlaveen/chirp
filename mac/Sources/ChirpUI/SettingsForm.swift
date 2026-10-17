import AppKit
import ChirpCore

/// What the Settings window shows. The window controller reads it from the system; the snapshots pass fixed values.
public struct SettingsState: Sendable {
    public var hotkey: KeyCombo = .optionSpace
    public var serverURL = ServerConfig.defaultURL.absoluteString
    public var tokenPresent = true
    public var launch: LaunchState = .off
    public var micGranted = true
    public var accessibilityGranted = true

    public init() {}
}

/// The Settings window content, plain AppKit on purpose: the Command Line Tools toolchain has no SwiftUI macro
/// plugins (@State etc.). Controls are exposed so the owner can attach targets and actions.
@MainActor
public final class SettingsForm {
    /// The content view, with its 20 pt margin pinned by constraints so `fittingSize` includes it on every side.
    public let view = NSView()
    public let hotkey = NSPopUpButton(frame: .zero, pullsDown: false)
    public let serverURL = NSTextField(string: "")
    public let launch: NSButton
    public let micButton = NSButton(title: "Grant…", target: nil, action: nil)
    public let accessibilityButton = NSButton(title: "Grant…", target: nil, action: nil)
    private let token = NSTextField(wrappingLabelWithString: "")
    private let micStatus = NSTextField(labelWithString: "")
    private let accessibilityStatus = NSTextField(labelWithString: "")

    public init(_ state: SettingsState) {
        for combo in KeyCombo.presets {
            hotkey.addItem(withTitle: combo.title)
            hotkey.lastItem?.representedObject = combo.id
        }
        serverURL.placeholderString = ServerConfig.defaultURL.absoluteString
        serverURL.widthAnchor.constraint(equalToConstant: 280).isActive = true
        launch = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        launch.allowsMixedState = true
        token.font = .systemFont(ofSize: 11)
        token.textColor = .secondaryLabelColor

        func hint(_ text: String) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: text)
            f.font = .systemFont(ofSize: 11)
            f.textColor = .secondaryLabelColor
            return f
        }
        func row(_ title: String, _ control: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: title)
            l.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let s = NSStackView(views: [l, control])
            s.alignment = .firstBaseline
            return s
        }
        let stack = NSStackView(views: [
            row("Hotkey", hotkey),
            hint("Tap to start/stop. Hold to talk, release to finish. Esc cancels."),
            launch,
            row("Server URL", serverURL),
            token,
            row("Microphone", NSStackView(views: [micStatus, micButton])),
            row("Accessibility", NSStackView(views: [accessibilityStatus, accessibilityButton])),
            hint("Accessibility lets Chirp insert text into other apps and send ⌘V."),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            view.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 20),
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 20),
        ])
        apply(state, full: true)
    }

    /// Fills the window. The periodic refresh passes `full: false` so it only follows the permissions and never
    /// overwrites what the user is typing or a login-item error shown on the checkbox.
    public func apply(_ s: SettingsState, full: Bool = false) {
        if full {
            hotkey.selectItem(withTitle: s.hotkey.title)
            serverURL.stringValue = s.serverURL
            token.stringValue = s.tokenPresent
                ? "Token read from ~/.config/chirp/token"
                : "No token at ~/.config/chirp/token — start chirp-server once to create it."
            launch.title = s.launch.menuTitle
            launch.state = switch s.launch { case .on: .on; case .needsApproval: .mixed; default: .off }
            launch.isEnabled = s.launch != .unavailable
        }
        micStatus.stringValue = s.micGranted ? "Granted ✓" : "Not granted"
        accessibilityStatus.stringValue = s.accessibilityGranted ? "Granted ✓" : "Not granted"
        micButton.isHidden = s.micGranted
        accessibilityButton.isHidden = s.accessibilityGranted
    }
}
