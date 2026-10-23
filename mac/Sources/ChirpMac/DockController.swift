import AppKit
import ChirpCore

/// Applies `DockPresence` to the app: a Dock icon and ⌘-Tab entry while Notes is open, the menu bar only otherwise.
@MainActor
final class DockController {
    private(set) var presence = DockPresence(alwaysShow: settings.alwaysShowInDock)
    private var applied: DockPresence.Policy?

    /// Window events from the Notes window and the recording state; each re-applies the activation policy.
    func update(_ change: (inout DockPresence) -> Void) {
        change(&presence)
        apply()
    }

    func apply() {
        let policy = presence.policy
        guard policy != applied else { return }
        applied = policy
        NSApp.setActivationPolicy(policy == .regular ? .regular : .accessory)
        chirpLog.info("dock policy=\(policy == .regular ? "regular" : "accessory", privacy: .public)")
    }
}
