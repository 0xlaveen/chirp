import AppKit
import ChirpCore
import ChirpUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller: DictationController
    private let openSettings: () -> Void
    private var inputName = InputDevice.defaultName()
    private var launchError: String?

    init(controller: DictationController, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.openSettings = openSettings
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        InputDevice.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.inputName = InputDevice.defaultName() }
        }
        refreshIcon()
    }

    func refreshIcon() {
        let symbol: String
        switch controller.state {
        case .idle: symbol = controller.health == nil ? "mic.slash" : "mic"
        case .connecting, .listening: symbol = "mic.fill"
        case .finalizing, .inserting: symbol = "waveform"
        case .error: symbol = "exclamationmark.triangle"
        }
        let button = item.button
        button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Chirp")
        // A persistent red dot while the server keeps recordings, so retention is never invisible.
        button?.attributedTitle = controller.debugRetention
            ? NSAttributedString(string: " ●", attributes: [.foregroundColor: NSColor.systemRed]) : NSAttributedString()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        inputName = InputDevice.defaultName()
        Task { await controller.refreshHealth() }
        build(menu)
    }

    private func build(_ menu: NSMenu) {
        var inputs = MenuInputs()
        inputs.state = controller.state
        inputs.health = controller.health
        inputs.healthError = controller.healthError
        inputs.debugRetention = controller.debugRetention
        inputs.inputName = inputName
        inputs.correctionOn = Settings.correction
        inputs.hotkey = Settings.hotkey
        inputs.micGranted = Permissions.microphoneGranted
        inputs.accessibilityGranted = Permissions.accessibilityGranted
        inputs.launch = LaunchAtLogin.state
        inputs.launchError = launchError
        menu.removeAllItems()
        for entry in MenuContent.entries(inputs) { menu.addItem(item(for: entry)) }
    }

    private func item(for entry: MenuEntry) -> NSMenuItem {
        if entry.isSeparator { return .separator() }
        let i = NSMenuItem(title: entry.title, action: selector(for: entry.action), keyEquivalent: "")
        if entry.action != nil { i.target = self }
        i.isEnabled = entry.action != nil || entry.submenu != nil
        i.state = switch entry.mark { case .off: .off; case .on: .on; case .mixed: .mixed }
        i.representedObject = if case .pickHotkey(let id) = entry.action { id } else { nil }
        let color: NSColor? = switch entry.tone { case .normal: nil; case .warning: .systemOrange; case .error: .systemRed }
        if let color { i.attributedTitle = NSAttributedString(string: entry.title, attributes: [.foregroundColor: color]) }
        if let sub = entry.submenu {
            let m = NSMenu()
            for e in sub { m.addItem(item(for: e)) }
            i.submenu = m
        }
        return i
    }

    private func selector(for action: MenuAction?) -> Selector? {
        switch action {
        case nil: nil
        case .toggleCorrection: #selector(toggleCorrection)
        case .pickHotkey: #selector(pickHotkey(_:))
        case .grantMic: #selector(grantMic)
        case .grantAX: #selector(grantAX)
        case .toggleLaunch: #selector(toggleLaunch)
        case .showSettings: #selector(showSettings)
        case .quit: #selector(quit)
        }
    }

    @objc private func pickHotkey(_ sender: NSMenuItem) {
        Settings.hotkey = KeyCombo.preset(id: sender.representedObject as? String)
        controller.registerHotkey()
    }
    @objc private func toggleCorrection() { Settings.correction.toggle() }
    @objc private func showSettings() { openSettings() }
    @objc private func toggleLaunch() {
        switch LaunchAtLogin.state {
        case .needsApproval: LaunchAtLogin.openSystemSettings()
        case .on: launchError = LaunchAtLogin.setEnabled(false)
        case .off: launchError = LaunchAtLogin.setEnabled(true)
        case .unavailable: break
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func grantMic() {
        Task {
            if Permissions.microphone == .notDetermined { _ = await Permissions.requestMicrophone() } else {
                Permissions.openSettings(.microphone)
            }
        }
    }
    @objc private func grantAX() {
        Permissions.promptAccessibility()
        Permissions.openSettings(.accessibility)
    }
}
