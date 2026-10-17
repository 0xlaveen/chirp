import ChirpCore
import Foundation

/// The only persistent client state besides the token file: plain UserDefaults preferences.
enum Settings {
    private static var defaults: UserDefaults { .standard }

    static var serverURL: String {
        get { defaults.string(forKey: "serverURL") ?? ServerConfig.defaultURL.absoluteString }
        set { defaults.set(newValue, forKey: "serverURL") }
    }
    /// One of `KeyCombo.presets` (⌃⌥Space by default).
    static var hotkey: KeyCombo {
        get { KeyCombo.preset(id: defaults.string(forKey: "hotkey")) }
        set { defaults.set(newValue.id, forKey: "hotkey") }
    }
    static var correction: Bool {
        get { defaults.bool(forKey: "correction") }
        set { defaults.set(newValue, forKey: "correction") }
    }
    static var didOnboard: Bool {
        get { defaults.bool(forKey: "didOnboard") }
        set { defaults.set(newValue, forKey: "didOnboard") }
    }

    static func serverConfig() -> ServerConfig { ServerConfig.load(urlString: serverURL) }
}
