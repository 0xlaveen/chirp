import AppKit
import ChirpCore
import ChirpUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DictationController()
    private let settingsWindow = SettingsWindowController()
    private let aboutWindow = AboutWindowController()
    private lazy var onboardingWindow = OnboardingWindowController(controller: controller)
    private var menu: MenuBarController?
    private var healthTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = MenuBarController(
            controller: controller,
            actions: .init(openSettings: { [settingsWindow] in settingsWindow.show(tab: $0) },
                           openSetup: { [onboardingWindow] in onboardingWindow.show() },
                           openAbout: { [aboutWindow] in aboutWindow.show() }))
        settingsWindow.onOpenSetup = { [onboardingWindow] in onboardingWindow.show() }
        settingsWindow.serverStatus = { [controller] in MenuContent.serverStatus(health: controller.health, healthError: controller.healthError) }
        settingsWindow.health = { [controller] in controller.health }
        settingsWindow.catalog = { [controller] in controller.styleCatalog }
        settingsWindow.onHotkeyChange = { [controller] in controller.registerHotkey() }
        settingsWindow.onRecordingChanged = { [controller] recording in
            // The live hotkey would start a dictation while the user is typing the new one.
            if recording { controller.suspendHotkey() } else { controller.registerHotkey() }
        }
        controller.onChange = { [weak self] in self?.menu?.refreshIcon() }
        controller.onHotkeyPressed = { [weak self] in self?.onboardingWindow.hotkeyPressed() }

        chirpLog.info("launch microphone=\(Permissions.microphone.rawValue, privacy: .public) accessibility=\(Permissions.accessibilityGranted, privacy: .public) hotkey=\(settings.hotkey.id, privacy: .public)")
        if !controller.registerHotkey() {
            NSLog("Chirp: could not register the hotkey \(settings.hotkey.title); it may be in use by another app")
        }

        Sounds.prepare()   // decode the cues now so the first start sound has no wait
        Task { await controller.refreshHealth() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [controller] _ in
            Task { @MainActor in await controller.refreshHealth() }
        }

        // First run: the setup window, not Settings. It records completion itself, only once finished.
        if !settings.didOnboard { onboardingWindow.show() }
    }
}
