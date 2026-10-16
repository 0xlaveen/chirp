import AppKit
import ChirpCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DictationController()
    private let settingsWindow = SettingsWindowController()
    private var menu: MenuBarController?
    private var healthTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = MenuBarController(controller: controller, openSettings: { [settingsWindow] in settingsWindow.show() })
        settingsWindow.onHotkeyChange = { [controller] in controller.registerHotkey() }
        controller.onChange = { [weak self] in self?.menu?.refreshIcon() }

        if !controller.registerHotkey() {
            NSLog("Chirp: could not register the hotkey \(Settings.hotkey.title); it may be in use by another app")
        }

        Task { await controller.refreshHealth() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [controller] _ in
            Task { @MainActor in await controller.refreshHealth() }
        }

        if !Settings.didOnboard {
            settingsWindow.show()
            Task {
                _ = await Permissions.requestMicrophone()
                if !Permissions.accessibilityGranted { Permissions.promptAccessibility() }
                // Only after both prompts, so an interrupted first launch onboards again.
                Settings.didOnboard = true
            }
        }
    }
}
