import Foundation

/// The only persistent client state besides the token file: plain UserDefaults preferences. The defaults are
/// injectable so tests use a throwaway suite.
public final class Preferences: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var serverURL: String {
        get { defaults.string(forKey: "serverURL") ?? ServerConfig.defaultURL.absoluteString }
        set { defaults.set(newValue, forKey: "serverURL") }
    }
    /// One of `KeyCombo.presets` (⌃⌥Space by default) or a recorded shortcut that passed `HotKeyValidation`.
    public var hotkey: KeyCombo {
        get { KeyCombo.resolve(id: defaults.string(forKey: "hotkey")) }
        set { defaults.set(newValue.id, forKey: "hotkey") }
    }
    /// Clean-up (the server's `correction` flag). Off by default.
    public var correction: Bool {
        get { defaults.bool(forKey: "correction") }
        set { defaults.set(newValue, forKey: "correction") }
    }
    /// Whether the HUD offers "Use raw" after a cleaned-up insertion. On by default.
    public var showRawAfterCleanup: Bool {
        get { defaults.object(forKey: "showRawAfterCleanup") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showRawAfterCleanup") }
    }
    /// UID of the input device the user picked; nil follows the system default input.
    public var inputDeviceUID: String? {
        get { defaults.string(forKey: "inputDeviceUID") }
        set { defaults.set(newValue, forKey: "inputDeviceUID") }
    }
    /// Subtle system sounds when dictation starts and stops. Off by default.
    public var soundsEnabled: Bool {
        get { defaults.bool(forKey: "soundsEnabled") }
        set { defaults.set(newValue, forKey: "soundsEnabled") }
    }
    /// Set only when the first-run window is finished (never on close), so an interrupted setup shows again.
    public var didOnboard: Bool {
        get { defaults.bool(forKey: "didOnboard") }
        set { defaults.set(newValue, forKey: "didOnboard") }
    }

    public func serverConfig() -> ServerConfig { ServerConfig.load(urlString: serverURL) }

    /// What the next `start` message asks for: the clean-up toggle is the wire `correction` flag.
    public func startOptions() -> StartOptions { StartOptions(client: "mac", correction: correction) }
}
