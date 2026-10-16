import AppKit
import ChirpCore
import KeyboardShortcuts
import LaunchAtLogin

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller: DictationController
    private let openSettings: () -> Void
    private var inputName = InputDevice.defaultName()

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

    private func line(_ title: String, color: NSColor? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        if let color { i.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color]) }
        return i
    }

    private func action(_ title: String, _ selector: Selector, on: Bool = false, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: enabled ? selector : nil, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        return i
    }

    private func build(_ menu: NSMenu) {
        menu.removeAllItems()
        switch controller.state {
        case .idle: menu.addItem(line("Chirp — ready"))
        case .connecting: menu.addItem(line("Connecting…"))
        case .listening: menu.addItem(line("Listening"))
        case .finalizing: menu.addItem(line("Finalizing"))
        case .inserting: menu.addItem(line("Inserting"))
        case .error(let m): menu.addItem(line(m, color: .systemRed))
        }
        if let h = controller.health {
            menu.addItem(line("Server: \(h.engine ?? "ok")\(h.ready == false ? " (loading…)" : "")"))
        } else {
            menu.addItem(line(controller.healthError ?? "Server: checking…", color: .systemOrange))
        }
        if controller.debugRetention { menu.addItem(line("DEBUG: recordings kept on the server", color: .systemRed)) }
        menu.addItem(line("Input: \(inputName ?? "none — no input device")"))
        menu.addItem(.separator())

        let h = controller.health
        if h?.correctionAvailable == true {
            let host = h?.correctionHost ?? "a remote LLM"
            let title = h?.correctionLeavesMachine == true ? "Correction — sends text to \(host)" : "Correction"
            menu.addItem(action(title, #selector(toggleCorrection), on: Settings.correction))
        } else {
            menu.addItem(action("Correction (not configured on server)", #selector(toggleCorrection), enabled: false))
        }
        let shortcut = KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "not set"
        menu.addItem(line("Hotkey: \(shortcut) — tap to toggle, hold to talk"))
        menu.addItem(action("Change Hotkey…", #selector(showSettings)))
        menu.addItem(.separator())

        menu.addItem(permissionItem("Microphone", granted: Permissions.microphoneGranted, #selector(grantMic)))
        menu.addItem(permissionItem("Accessibility", granted: Permissions.accessibilityGranted, #selector(grantAX)))
        menu.addItem(.separator())
        menu.addItem(action("Launch at Login", #selector(toggleLaunch), on: LaunchAtLogin.isEnabled))
        menu.addItem(action("Settings…", #selector(showSettings)))
        menu.addItem(action("Quit Chirp", #selector(quit)))
    }

    private func permissionItem(_ name: String, granted: Bool, _ selector: Selector) -> NSMenuItem {
        granted ? line("\(name): granted ✓") : action("\(name): not granted — Grant…", selector)
    }

    @objc private func toggleCorrection() { Settings.correction.toggle() }
    @objc private func showSettings() { openSettings() }
    @objc private func toggleLaunch() { LaunchAtLogin.isEnabled.toggle() }
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
