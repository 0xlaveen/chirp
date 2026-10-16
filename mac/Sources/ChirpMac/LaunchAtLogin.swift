import Foundation
import ServiceManagement

/// Launch at login through `SMAppService`. It needs a bundled app: from `swift run`, or for a build the
/// system doesn't know (status `.notFound`), it reports `.unavailable` instead of failing.
enum LaunchAtLogin {
    enum State: Equatable {
        case on, off
        /// Registered, but macOS wants the user to allow it in System Settings → General → Login Items.
        case needsApproval
        case unavailable
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .notRegistered: .off
        case .requiresApproval: .needsApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    /// Returns a short error message when the change failed (e.g. unsigned or ad-hoc build), nil on success.
    @discardableResult
    static func setEnabled(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    static var menuTitle: String {
        switch state {
        case .on, .off: "Launch at Login"
        case .needsApproval: "Launch at Login — approve in System Settings…"
        case .unavailable: "Launch at Login (unavailable for this build)"
        }
    }
}
