import AppKit
import UniformTypeIdentifiers
import ChirpCore
import ChirpUI

@MainActor
final class SettingsWindowController: NSObject, NSTextFieldDelegate {
    /// Called after the hotkey preset changes so the app can re-register it.
    var onHotkeyChange: (() -> Void)?
    /// The shortcut recorder started or stopped listening.
    var onRecordingChanged: ((Bool) -> Void)?
    /// The server's state for the Status row, from the app's last health check.
    var serverStatus: () -> (text: String, tone: MenuEntry.Tone) = { ("Checking…", .warning) }
    /// The server's last health, for the styles it offers.
    var health: () -> Health? = { nil }
    private var window: NSWindow?
    private var form: SettingsForm?
    private var refreshTimer: Timer?

    private var state: SettingsState {
        var s = SettingsState()
        s.hotkey = settings.hotkey
        s.serverURL = settings.serverURL
        s.tokenPresent = ServerConfig.readToken() != nil
        s.launch = LaunchAtLogin.state
        s.soundsEnabled = settings.soundsEnabled
        s.soundPack = settings.soundPack
        s.soundVolume = settings.soundVolume
        s.customStart = settings.customStartSound
        s.customStop = settings.customStopSound
        s.micGranted = Permissions.microphoneGranted
        s.accessibilityGranted = Permissions.accessibilityGranted
        (s.serverStatus, s.serverStatusTone) = serverStatus()
        s.cleanupStyle = settings.correctionProfile
        s.customInstructions = settings.correctionInstructions
        s.insertRawFirst = settings.insertRawFirst
        s.appStyles = settings.appStyles
        let health = health()
        s.profiles = CorrectionProfile.offered(by: health)
        s.serverOffersStyles = health == nil || health?.correctionProfiles != nil
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
        form.recorder.onCapture = { [weak self] combo in
            settings.hotkey = combo
            self?.form?.fillHotkeyMenu(selecting: combo)
            self?.onHotkeyChange?()
        }
        form.recorder.onRecordingChanged = { [weak self] recording in self?.onRecordingChanged?(recording) }
        form.sounds.target = self
        form.sounds.action = #selector(toggleSounds(_:))
        form.soundPack.target = self
        form.soundPack.action = #selector(packChanged(_:))
        form.volume.target = self
        form.volume.action = #selector(volumeChanged(_:))
        for (button, action) in [(form.previewStart, #selector(previewStart)), (form.previewStop, #selector(previewStop)),
                                 (form.chooseStart, #selector(chooseStart)), (form.chooseStop, #selector(chooseStop)),
                                 (form.removeStart, #selector(removeStart)), (form.removeStop, #selector(removeStop))] {
            button.target = self
            button.action = action
        }
        form.style.target = self
        form.style.action = #selector(styleChanged(_:))
        form.instructions.onChange = { settings.correctionInstructions = $0 }
        form.insertRawFirst.target = self
        form.insertRawFirst.action = #selector(toggleRawFirst(_:))
        form.appStyles.onChange = { settings.appStyles = $0 }
        form.appStyles.onAdd = { [weak self] button in self?.showAppChooser(from: button) }
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
        settings.hotkey = KeyCombo.resolve(id: sender.selectedItem?.representedObject as? String)
        onHotkeyChange?()
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        settings.correctionProfile = id
        form?.fillStyleMenu(CorrectionProfile.offered(by: health()), selecting: id, offered: health()?.correctionProfiles != nil || health() == nil)
    }

    @objc private func toggleRawFirst(_ sender: NSButton) {
        settings.insertRawFirst = sender.state == .on
    }

    /// "+": the running apps that have no rule yet, then a file chooser for any other app.
    private func showAppChooser(from button: NSView) {
        let menu = NSMenu()
        let have = Set(settings.appStyles.map(\.bundleID))
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !have.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        for app in running {
            let item = NSMenuItem(title: app.localizedName ?? app.bundleIdentifier!, action: #selector(addApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.bundleIdentifier
            item.image = app.icon.map { icon in
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 16, height: 16)
                return small
            }
            menu.addItem(item)
        }
        if !running.isEmpty { menu.addItem(.separator()) }
        let choose = NSMenuItem(title: "Choose App…", action: #selector(chooseApp), keyEquivalent: "")
        choose.target = self
        menu.addItem(choose)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func addApp(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { form?.appStyles.add(bundleID: id) }
    }

    @objc private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        form?.appStyles.add(bundleID: id)
    }

    @objc private func toggleSounds(_ sender: NSButton) {
        settings.soundsEnabled = sender.state == .on
    }

    // MARK: sounds

    @objc private func packChanged(_ sender: NSPopUpButton) {
        let pack = SoundPack.resolve(id: sender.selectedItem?.representedObject as? String)
        let previous = settings.soundPack
        settings.soundPack = pack
        form?.showPack(pack)
        form?.setCustomSounds(start: settings.customStartSound, stop: settings.customStopSound)
        // "Custom…" with nothing chosen yet goes straight to the file chooser; giving up keeps the old pack.
        if pack == .custom, settings.customStartSound == nil, settings.customStopSound == nil {
            if !importSound(for: .start) {
                settings.soundPack = previous
                form?.showPack(previous)
            }
        }
        Sounds.prepare()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        let fraction = sender.doubleValue / 100
        settings.soundVolume = fraction
        form?.setVolume(fraction)
        // Let go of the slider and hear the level (not on every tick of the drag).
        if NSApp.currentEvent?.type == .leftMouseUp { Sounds.play(.start) }
    }

    @objc private func previewStart() { Sounds.prepare(); Sounds.play(.start) }
    @objc private func previewStop() { Sounds.prepare(); Sounds.play(.stop) }
    @objc private func chooseStart() { importSound(for: .start) }
    @objc private func chooseStop() { importSound(for: .stop) }
    @objc private func removeStart() { removeSound(for: .start) }
    @objc private func removeStop() { removeSound(for: .stop) }

    /// Asks for an audio file, copies it into Application Support and remembers the copy. Returns false when the user
    /// cancelled or the file could not be used (the reason shows under the row).
    @discardableResult
    private func importSound(for cue: SoundCue) -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]   // aiff, wav, caf, m4a, mp3, …
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = cue == .start ? "Choose the sound that plays when dictation starts."
                                      : "Choose the sound that plays when dictation stops."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let imported = try Sounds.customStore.importFile(from: url, cue: cue, replacing: settings.customSound(for: cue))
            if cue == .start { settings.customStartSound = imported } else { settings.customStopSound = imported }
            form?.setCustomSounds(start: settings.customStartSound, stop: settings.customStopSound)
            Sounds.prepare()
            Sounds.play(cue)
            return true
        } catch {
            form?.setCustomSounds(start: settings.customStartSound, stop: settings.customStopSound, error: error.localizedDescription)
            return false
        }
    }

    private func removeSound(for cue: SoundCue) {
        Sounds.customStore.remove(settings.customSound(for: cue))
        if cue == .start { settings.customStartSound = nil } else { settings.customStopSound = nil }
        form?.setCustomSounds(start: settings.customStartSound, stop: settings.customStopSound)
        Sounds.prepare()
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
