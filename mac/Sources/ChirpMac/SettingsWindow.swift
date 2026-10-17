import AppKit
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
    /// The styles with their default prompts (live, or the last-known copy).
    var catalog: () -> StyleCatalog = { .unavailable }
    private var testTask: Task<Void, Never>?
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
        s.micGranted = Permissions.microphoneGranted
        s.accessibilityGranted = Permissions.accessibilityGranted
        (s.serverStatus, s.serverStatusTone) = serverStatus()
        s.cleanupStyle = settings.correctionProfile
        s.stylePrompts = settings.correctionPrompts
        s.insertRawFirst = settings.insertRawFirst
        s.showChanges = settings.showChangesAfterCleanup
        s.appStyles = settings.appStyles
        let health = health()
        let catalog = catalog()
        s.catalog = catalog
        s.profiles = catalog.source == .unavailable ? CorrectionProfile.offered(by: health) : catalog.profiles
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
        form.style.target = self
        form.style.action = #selector(styleChanged(_:))
        form.prompts.onEdit = { [weak self] id, text in
            guard let self else { return }
            settings.setPrompt(text, for: id, in: self.catalog())
        }
        form.prompts.onReset = { settings.resetPrompt(for: $0) }
        form.appStyles.testButton.target = self
        form.appStyles.testButton.action = #selector(testAppStyle)
        form.showChanges.target = self
        form.showChanges.action = #selector(toggleShowChanges(_:))
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
        form?.fillStyleMenu(state.profiles, selecting: id, offered: state.serverOffersStyles)
    }

    /// "Test": Settings itself is frontmost while the button is pressed, so wait a moment for the user to switch to the
    /// app to check, then say which style applies to it.
    @objc private func testAppStyle() {
        testTask?.cancel()
        form?.appStyles.showTestResult("Switch to the app you want to check. Reading it in 3 seconds…")
        testTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            let app = NSWorkspace.shared.frontmostApplication
            let id = app?.bundleIdentifier
            guard id != Bundle.main.bundleIdentifier else {
                self.form?.appStyles.showTestResult("Chirp itself was frontmost. Press Test, then switch to another app within 3 seconds.")
                return
            }
            let state = self.state
            let resolved = settings.cleanupStyle(frontmostBundleID: id, available: state.serverOffersStyles ? state.profiles : nil)
            let name = state.profiles.first { $0.id == resolved.profile }?.name ?? CorrectionProfile.displayName(for: resolved.profile)
            let appName = id.map { AppNames.name(for: $0) } ?? app?.localizedName
            self.form?.appStyles.showTestResult(CleanupStyle.testSummary(appName: appName, resolved: resolved, styleName: name))
        }
    }

    @objc private func toggleShowChanges(_ sender: NSButton) {
        settings.showChangesAfterCleanup = sender.state == .on
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
