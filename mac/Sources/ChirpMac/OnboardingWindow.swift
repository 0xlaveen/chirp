import AppKit
import ChirpCore
import ChirpUI

/// The first-run window: Welcome, Microphone, Accessibility, server and a Try it step, each with live status and a Fix
/// button. It opens on first launch and from the menu ("Set Up Chirp…"). `settings.didOnboard` is written only when
/// the last step is finished, never when the window is closed early.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    var onOpenModels: (() -> Void)?
    private let controller: DictationController
    private var flow = OnboardingFlow()
    private var window: NSWindow?
    private var view: OnboardingView?
    private var refreshTimer: Timer?
    private var ticks = 0

    init(controller: DictationController) {
        self.controller = controller
        super.init()
    }

    private var checks: OnboardingChecks {
        var c = OnboardingChecks()
        c.microphone = switch Permissions.microphone {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
        c.accessibility = Permissions.accessibilityGranted
        let config = settings.serverConfig()
        c.server = ServerCheck.of(tokenPresent: config.token != nil, health: controller.health,
                                  healthError: controller.healthError, host: config.host)
        return c
    }

    private var state: OnboardingState {
        var s = OnboardingState()
        s.flow = flow
        s.checks = checks
        s.hotkey = settings.hotkey
        s.localModelsAvailable = settings.serverConfig().isLoopback
        return s
    }

    func show() {
        if window?.isVisible != true { flow.restart() }
        if window == nil { makeWindow() }
        refresh()
        Task { await controller.refreshHealth() }
        refreshTimer?.invalidate()
        ticks = 0
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() {
        let v = OnboardingView(icon: NSApp.applicationIconImage)
        v.primary.target = self; v.primary.action = #selector(primaryPressed)
        v.back.target = self; v.back.action = #selector(backPressed)
        v.fix.target = self; v.fix.action = #selector(fixPressed)
        view = v
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingView.size),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Set Up Chirp"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = v
        w.center()
        window = w
    }

    private func tick() {
        ticks += 1
        if ticks % 3 == 0 { Task { await controller.refreshHealth() } }
        refresh()
    }

    private func refresh() {
        guard let view else { return }
        view.apply(state)
        if flow.step == .tryIt, !flow.heardHotkey, window?.firstResponder !== view.tryField.currentEditor() {
            window?.makeFirstResponder(view.tryField)
        }
    }

    /// The dictation hotkey was pressed: the Try it step turns green.
    func hotkeyPressed() {
        guard window?.isVisible == true, flow.step == .tryIt, !flow.heardHotkey else { return }
        flow.heardHotkey = true
        refresh()
    }

    @objc private func primaryPressed() {
        let finished = flow.advance(markDone: { settings.didOnboard = true })
        if finished { window?.close() } else { refresh() }
    }

    @objc private func backPressed() {
        flow.back()
        refresh()
    }

    @objc private func fixPressed() {
        switch flow.step {
        case .microphone:
            Task {
                if Permissions.microphone == .notDetermined { _ = await Permissions.requestMicrophone() }
                else { Permissions.openSettings(.microphone) }
            }
        case .accessibility:
            Permissions.promptAccessibility()
            Permissions.openSettings(.accessibility)
        case .server:
            if settings.serverConfig().isLoopback { onOpenModels?(); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(DoctorHelp.clipboardText(serverURL: settings.serverURL), forType: .string)
        case .welcome, .tryIt: break
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
