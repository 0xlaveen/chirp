import AppKit
import ChirpCore
import ChirpUI

@MainActor
final class SettingsWindowController: NSObject, NSTextFieldDelegate {
    /// Called after the hotkey preset changes so the app can re-register it.
    var onHotkeyChange: (() -> Void)?
    /// The server's state for the Status row, from the app's last health check.
    var serverStatus: () -> (text: String, tone: MenuEntry.Tone) = { ("Checking…", .warning) }
    private var window: NSWindow?
    private var form: SettingsForm?
    private var refreshTimer: Timer?

    private var state: SettingsState {
        var s = SettingsState()
        s.hotkey = settings.hotkey
        s.serverURL = settings.serverURL
        s.tokenPresent = ServerConfig.readToken() != nil
        s.launch = LaunchAtLogin.state
        s.micGranted = Permissions.microphoneGranted
        s.accessibilityGranted = Permissions.accessibilityGranted
        (s.serverStatus, s.serverStatusTone) = serverStatus()
        return s
    }

    func show() {
        if window == nil { window = makeWindow() }
        form?.apply(state)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.form?.apply(self.state) } }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Ordering the window front lets AppKit pick the first text field; park focus on the content instead.
        if let window, let form { window.makeFirstResponder(form.view) }
    }

    private func makeWindow() -> NSWindow {
        let form = SettingsForm(state)
        form.hotkey.target = self
        form.hotkey.action = #selector(hotkeyChanged(_:))
        form.serverURL.delegate = self
        form.launch.target = self
        form.launch.action = #selector(toggleLaunch(_:))
        form.micButton.target = self
        form.micButton.action = #selector(grantMic)
        form.accessibilityButton.target = self
        form.accessibilityButton.action = #selector(grantAX)
        self.form = form

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Chirp Settings"
        w.isReleasedWhenClosed = false
        form.install(in: w)
        w.center()
        return w
    }

    func controlTextDidChange(_ obj: Notification) {
        if let f = obj.object as? NSTextField { settings.serverURL = f.stringValue }
    }

    @objc private func hotkeyChanged(_ sender: NSPopUpButton) {
        settings.hotkey = KeyCombo.preset(id: sender.selectedItem?.representedObject as? String)
        onHotkeyChange?()
    }

    @objc private func toggleLaunch(_ sender: NSButton) {
        let error = LaunchAtLogin.toggle()
        sender.state = LaunchAtLogin.state == .on ? .on : .off
        form?.setLaunchError(error)
    }
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
