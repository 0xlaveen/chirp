import AppKit
import ChirpCore
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DictationController()
    private let settingsWindow = SettingsWindowController()
    private var menu: MenuBarController?
    private var healthTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = MenuBarController(controller: controller, openSettings: { [settingsWindow] in settingsWindow.show() })
        controller.onChange = { [weak self] in self?.menu?.refreshIcon() }

        KeyboardShortcuts.onKeyDown(for: .dictate) { [controller] in MainActor.assumeIsolated { controller.hotkeyDown() } }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [controller] in MainActor.assumeIsolated { controller.hotkeyUp() } }
        KeyboardShortcuts.onKeyDown(for: .cancelDictation) { [controller] in MainActor.assumeIsolated { controller.escape() } }
        KeyboardShortcuts.disable(.cancelDictation)

        Task { await controller.refreshHealth() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [controller] _ in
            Task { @MainActor in await controller.refreshHealth() }
        }

        if !Settings.didOnboard {
            Settings.didOnboard = true
            settingsWindow.show()
            Task {
                _ = await Permissions.requestMicrophone()
                if !Permissions.accessibilityGranted { Permissions.promptAccessibility() }
            }
        }
    }
}
