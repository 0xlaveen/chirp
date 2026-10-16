import AppKit
import ChirpCore
import KeyboardShortcuts
import LaunchAtLogin

/// Plain AppKit on purpose: the Command Line Tools toolchain has no SwiftUI macro plugins (@State etc.).
@MainActor
final class SettingsWindowController: NSObject, NSTextFieldDelegate {
    private var window: NSWindow?
    private var micStatus: NSTextField?
    private var axStatus: NSTextField?
    private var micButton: NSButton?
    private var axButton: NSButton?
    private var refreshTimer: Timer?

    func show() {
        if window == nil { window = makeWindow() }
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func label(_ text: String, small: Bool = false) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        if small { f.font = .systemFont(ofSize: 11); f.textColor = .secondaryLabelColor }
        return f
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let l = label(title)
        l.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let s = NSStackView(views: [l, control])
        s.alignment = .firstBaseline
        return s
    }

    private func makeWindow() -> NSWindow {
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .dictate)

        let url = NSTextField(string: Settings.serverURL)
        url.placeholderString = ServerConfig.defaultURL.absoluteString
        url.delegate = self
        url.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let launch = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(toggleLaunch(_:)))
        launch.state = LaunchAtLogin.isEnabled ? .on : .off

        let token = label(ServerConfig.readToken() == nil
            ? "No token at ~/.config/chirp/token — start chirp-server once to create it."
            : "Token read from ~/.config/chirp/token", small: true)

        let mic = label(""), ax = label("")
        let micB = NSButton(title: "Grant…", target: self, action: #selector(grantMic))
        let axB = NSButton(title: "Grant…", target: self, action: #selector(grantAX))
        micStatus = mic; axStatus = ax; micButton = micB; axButton = axB

        let stack = NSStackView(views: [
            row("Hotkey", recorder),
            label("Tap to start/stop. Hold to talk, release to finish. Esc cancels.", small: true),
            launch,
            row("Server URL", url),
            token,
            row("Microphone", NSStackView(views: [mic, micB])),
            row("Accessibility", NSStackView(views: [ax, axB])),
            label("Accessibility lets Chirp insert text into other apps and send ⌘V.", small: true),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Chirp Settings"
        w.contentView = stack
        w.isReleasedWhenClosed = false
        w.setContentSize(stack.fittingSize)
        w.center()
        return w
    }

    private func refresh() {
        let mic = Permissions.microphoneGranted, ax = Permissions.accessibilityGranted
        micStatus?.stringValue = mic ? "Granted ✓" : "Not granted"
        axStatus?.stringValue = ax ? "Granted ✓" : "Not granted"
        micButton?.isHidden = mic
        axButton?.isHidden = ax
    }

    func controlTextDidChange(_ obj: Notification) {
        if let f = obj.object as? NSTextField { Settings.serverURL = f.stringValue }
    }

    @objc private func toggleLaunch(_ sender: NSButton) { LaunchAtLogin.isEnabled = sender.state == .on }
    @objc private func grantMic() {
        Task {
            if Permissions.microphone == .notDetermined { _ = await Permissions.requestMicrophone() }
            else { Permissions.openSettings(.microphone) }
        }
    }
    @objc private func grantAX() {
        Permissions.promptAccessibility()
        Permissions.openSettings(.accessibility)
    }
}
