import AppKit
import ChirpCore
import ChirpUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller: DictationController
    private let actions: Actions
    private var launchError: String?
    private let badge = NSView()
    private let glyphs = Glyphs()
    private var pulseTimer: Timer?
    private var pulsePhase = 0

    /// The windows the menu opens.
    struct Actions {
        var openSettings: () -> Void
        var openSetup: () -> Void
        var openAbout: () -> Void
    }

    init(controller: DictationController, actions: Actions) {
        self.controller = controller
        self.actions = actions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        installBadge()
        refreshIcon()
    }

    // MARK: status icon

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func refreshIcon() {
        let icon = StatusIcon.of(state: controller.state, serverReachable: controller.health != nil,
                                 debugRetention: controller.debugRetention, reduceMotion: reduceMotion)
        guard let button = item.button else { return }
        switch icon.glyph {
        case .idle: button.image = glyphs.idle ?? Self.symbol(controller.health == nil ? "mic.slash" : "mic")
        case .listening: button.image = glyphs.listening(waveAlpha: StatusIcon.waveAlpha(phase: pulsePhase, reduceMotion: reduceMotion))
            ?? Self.symbol("waveform")
        case .error: button.image = Self.symbol("exclamationmark.triangle")
        }
        button.alphaValue = icon.dimmed ? 0.45 : 1
        button.setAccessibilityLabel(icon.accessibilityLabel)
        button.toolTip = icon.accessibilityLabel
        badge.isHidden = !icon.debugBadge
        setPulsing(icon.animatesWaves)
    }

    private func setPulsing(_ on: Bool) {
        guard on != (pulseTimer != nil) else { return }
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulsePhase = 0
        guard on else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: StatusIcon.pulseInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pulsePhase += 1
                self.refreshIcon()
            }
        }
    }

    /// A small red dot at the icon's top right while the server keeps recordings, so retention is never invisible.
    private func installBadge() {
        guard let button = item.button else { return }
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 3.5
        badge.layer?.borderWidth = 1
        badge.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 7), badge.heightAnchor.constraint(equalToConstant: 7),
            badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
            badge.topAnchor.constraint(equalTo: button.topAnchor, constant: 3),
        ])
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "Chirp")
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        Task { await controller.refreshHealth() }
        build(menu)
    }

    private func build(_ menu: NSMenu) {
        var inputs = MenuInputs()
        inputs.state = controller.state
        inputs.health = controller.health
        inputs.healthError = controller.healthError
        inputs.debugRetention = controller.debugRetention
        inputs.inputs = InputDevice.all().map(\.input)
        inputs.defaultInput = InputDevice.systemDefault()?.input
        inputs.chosenInputUID = settings.inputDeviceUID
        inputs.cleanupOn = settings.correction
        inputs.showRawAfterCleanup = settings.showRawAfterCleanup
        inputs.styleID = settings.correctionProfile
        inputs.hotkey = settings.hotkey
        inputs.soundsEnabled = settings.soundsEnabled
        inputs.serverURL = settings.serverURL
        inputs.micGranted = Permissions.microphoneGranted
        inputs.accessibilityGranted = Permissions.accessibilityGranted
        inputs.launch = LaunchAtLogin.state
        inputs.launchError = launchError
        menu.removeAllItems()
        let entries = MenuContent.entries(inputs)
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            index += 1
            guard entry.showsAppIcon else { menu.addItem(item(for: entry)); continue }
            // The header block: this row plus the status lines up to the next separator, as one custom view.
            let start = index
            while index < entries.count, !entries[index].isSeparator { index += 1 }
            menu.addItem(headerItem(entry, lines: Array(entries[start..<index])))
        }
    }

    private func headerItem(_ header: MenuEntry, lines: [MenuEntry]) -> NSMenuItem {
        let i = NSMenuItem()
        i.view = MenuHeaderView(title: header.title, hint: header.subtitle, lines: lines, icon: NSApp.applicationIconImage)
        return i
    }

    private func item(for entry: MenuEntry) -> NSMenuItem {
        if entry.isSeparator { return .separator() }
        if entry.isHeader { return .sectionHeader(title: entry.title) }
        let i = NSMenuItem(title: entry.title, action: selector(for: entry.action), keyEquivalent: entry.keyEquivalent ?? "")
        if entry.keyEquivalent != nil { i.keyEquivalentModifierMask = .command }
        if entry.action != nil { i.target = self }
        i.isEnabled = entry.action != nil || entry.submenu != nil
        i.state = switch entry.mark { case .off: .off; case .on: .on; case .mixed: .mixed }
        i.representedObject = entry.action?.payload
        i.subtitle = entry.subtitle
        if let name = entry.symbol { i.image = MenuStyle.symbol(name, tone: entry.symbolTone ?? entry.tone) }
        // Warnings and errors that can be acted on keep their colour; plain rows use the system's.
        if entry.tone == .warning || entry.tone == .error, entry.action != nil || entry.submenu != nil {
            i.attributedTitle = NSAttributedString(string: entry.title, attributes: [
                .foregroundColor: MenuStyle.textColor(entry.tone), .font: NSFont.menuFont(ofSize: 0)])
        }
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
        case .toggleDictation: #selector(toggleDictation)
        case .pickInput: #selector(pickInput(_:))
        case .toggleCleanup: #selector(toggleCleanup)
        case .toggleShowRaw: #selector(toggleShowRaw)
        case .pickHotkey: #selector(pickHotkey(_:))
        case .pickStyle: #selector(pickStyle(_:))
        case .copyDoctor: #selector(copyDoctor)
        case .grantMic: #selector(grantMic)
        case .grantAX: #selector(grantAX)
        case .toggleSounds: #selector(toggleSounds)
        case .toggleLaunch: #selector(toggleLaunch)
        case .showSettings: #selector(showSettings)
        case .showSetup: #selector(showSetup)
        case .showAbout: #selector(showAbout)
        case .quit: #selector(quit)
        }
    }

    @objc private func toggleDictation() { controller.toggleDictation() }
    @objc private func pickInput(_ sender: NSMenuItem) { settings.inputDeviceUID = sender.representedObject as? String }
    @objc private func toggleCleanup() { settings.correction.toggle() }
    @objc private func toggleShowRaw() { settings.showRawAfterCleanup.toggle() }
    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.correctionProfile = id
        // Custom needs instructions: open Settings, where they are written.
        if id == CorrectionProfile.customID { actions.openSettings() }
    }
    @objc private func pickHotkey(_ sender: NSMenuItem) {
        settings.hotkey = KeyCombo.resolve(id: sender.representedObject as? String)
        controller.registerHotkey()
    }
    @objc private func copyDoctor() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DoctorHelp.clipboardText(serverURL: settings.serverURL), forType: .string)
    }
    @objc private func showSettings() { actions.openSettings() }
    @objc private func showSetup() { actions.openSetup() }
    @objc private func showAbout() { actions.openAbout() }
    @objc private func toggleSounds() { settings.soundsEnabled.toggle() }
    @objc private func toggleLaunch() { launchError = LaunchAtLogin.toggle() }
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

/// The bird glyphs (template images in Contents/Resources). The waves are the listening glyph minus the idle bird, so
/// the pulse can fade them while the bird stays put. SF Symbols stand in when run outside the bundle.
@MainActor
private final class Glyphs {
    let idle: NSImage?
    private let full: NSImage?
    private let waves: NSImage?

    init() {
        idle = Self.load("MenuBarIdle")
        full = Self.load("MenuBarListening")
        if let full, let idle {
            waves = NSImage(size: full.size, flipped: false) { rect in
                full.draw(in: rect)
                idle.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
                return true
            }
        } else {
            waves = nil
        }
    }

    func listening(waveAlpha: Double) -> NSImage? {
        guard let idle, let waves else { return full }
        guard waveAlpha < 1 else { return full }
        let image = NSImage(size: idle.size, flipped: false) { rect in
            idle.draw(in: rect)
            waves.draw(in: rect, from: .zero, operation: .sourceOver, fraction: waveAlpha)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Chirp"
        return image
    }

    private static func load(_ name: String) -> NSImage? {
        guard let image = Bundle.main.image(forResource: name) else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = "Chirp"
        return image
    }
}
