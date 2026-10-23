import AppKit
import ChirpCore
import ChirpUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DictationController()
    private let settingsWindow = SettingsWindowController()
    private let localModelsWindow = LocalModelsWindowController()
    private let pairingWindow = PairingWindowController()
    private let notes = NotesController()
    private lazy var notesWindow = NotesWindowController(notes: notes)
    private lazy var onboardingWindow = OnboardingWindowController(controller: controller)
    private var menu: MenuBarController?
    private var healthTimer: Timer?

    func applicationWillTerminate(_ notification: Notification) { localModelsWindow.stop() }

    /// Quit stops Notes gracefully (at most 5 s), then asks about unsaved notes before the app goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard notes.isActive || notes.model.document.isDirty else { return .terminateNow }
        Task {
            await notes.stopForQuit()
            self.notesWindow.confirmDiscard { ok in
                NSApp.reply(toApplicationShouldTerminate: ok)
            }
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = MenuBarController(
            controller: controller,
            actions: .init(openSettings: { [settingsWindow] in settingsWindow.show(tab: $0) },
                           openSetup: { [onboardingWindow] in onboardingWindow.show() },
                           toggleNotes: { [notes] in notes.toggle(fromHotkey: false) },
                           showNotes: { [notesWindow] in notesWindow.show() },
                           notes: { [notes] in notes.menuState },
                           setRunning: { [notes] in notes.setRunning($0) }))
        settingsWindow.onOpenSetup = { [onboardingWindow] in onboardingWindow.show() }
        settingsWindow.onOpenModels = { [localModelsWindow] in localModelsWindow.show() }
        settingsWindow.onPairPhone = { [pairingWindow] in pairingWindow.show() }
        settingsWindow.onOpenNotes = { [notesWindow] in notesWindow.show() }
        onboardingWindow.onOpenModels = { [localModelsWindow] in localModelsWindow.show() }
        localModelsWindow.onServerChanged = { [controller] in Task { await controller.refreshHealth() } }
        settingsWindow.serverStatus = { [controller] in MenuContent.serverStatus(health: controller.health, healthError: controller.healthError) }
        settingsWindow.health = { [controller] in controller.health }
        settingsWindow.catalog = { [controller] in controller.styleCatalog }
        settingsWindow.onHotkeyChange = { [controller] in controller.registerHotkey() }
        settingsWindow.onRecordingChanged = { [controller] recording in
            // The live hotkey would start a dictation while the user is typing the new one.
            if recording { controller.suspendHotkey() } else { controller.registerHotkey() }
        }
        controller.onChange = { [weak self] in
            self?.menu?.refreshIcon()
            self?.notes.healthChanged()
        }
        controller.isBlocked = { [notes] in notes.isActive }
        notes.health = { [controller] in controller.health }
        notes.isDictating = { [controller] in controller.state.isActive }
        notes.onChange = { [weak self] in self?.menu?.refreshIcon() }
        notes.onShowWindow = { [weak self] focus in self?.notesWindow.show(focus: focus) }
        settingsWindow.onNotesRecoveryCopyChange = { [notes] in notes.recoveryCopyChanged() }
        notesWindow.onOpenModels = { [localModelsWindow] in localModelsWindow.show() }
        settingsWindow.onRemoveSpeakerModel = { [notes] in notes.removeSpeakerModel() }
        notes.onSpeakerModelChange = { [settingsWindow] in settingsWindow.speakerModelChanged() }
        controller.onHotkeyPressed = { [weak self] in self?.onboardingWindow.hotkeyPressed() }

        chirpLog.info("launch microphone=\(Permissions.microphone.rawValue, privacy: .public) accessibility=\(Permissions.accessibilityGranted, privacy: .public) hotkey=\(settings.hotkey.id, privacy: .public)")
        if !controller.registerHotkey() {
            NSLog("Chirp: could not register the hotkey \(settings.hotkey.title); it may be in use by another app")
        }

        if !notes.registerHotkey() {
            NSLog("Chirp: could not register the Live Notes hotkey ⌃⌥N; it may be in use by another app")
        }

        Sounds.prepare()   // decode the cues now so the first start sound has no wait
        Task { await controller.refreshHealth() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [controller] _ in
            Task { @MainActor in
                controller.retryHotkeyIfNeeded()
                await controller.refreshHealth()
            }
        }
        // Posted when any app's Accessibility access changes; the trust check settles a moment later.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.accessibility.api"),
                                                            object: nil, queue: .main) { [controller] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                controller.retryHotkeyIfNeeded()
            }
        }

        // A session the last run did not end with Save or Discard (a crash, a force quit, a power loss) comes back here.
        if notes.checkRecovery() { notesWindow.show(focus: false) }

        // First run: the setup window, not Settings. It records completion itself, only once finished.
        if !settings.didOnboard { onboardingWindow.show() }
        if ProcessInfo.processInfo.arguments.contains("--models") { localModelsWindow.show() }
    }
}
