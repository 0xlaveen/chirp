import ChirpCore
import ChirpUI
import Foundation
import ServiceManagement

/// Launch at login through a user LaunchAgent (see `LaunchAgent`). `SMAppService.mainApp` is not used to register:
/// it fails for a self-signed app in ~/Applications. A registration an earlier build made is still cleaned up when
/// the user turns the toggle off.
enum LaunchAtLogin {
    typealias State = LaunchState

    /// nil outside a bundled app (e.g. `swift run`), where there is no app path to launch.
    private static var agent: LaunchAgent? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return nil }
        return LaunchAgent(
            appPath: url.path,
            launchAgentsDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            fileSystem: DiskFileSystem())
    }

    static var state: State {
        guard let agent else { return .unavailable }
        return agent.isEnabled || SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Returns a short error message when the change failed, nil on success.
    @discardableResult
    static func setEnabled(_ on: Bool) -> String? {
        guard let agent else { return "run Chirp from its app bundle" }
        do {
            try agent.setEnabled(on)
            if !on, SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Flips the current state and returns an error message, nil on success.
    @discardableResult
    static func toggle() -> String? { setEnabled(state != .on) }
}

private struct DiskFileSystem: LaunchAgentFileSystem {
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
}
