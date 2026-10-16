import ChirpCore
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Default ⌥Space; key-down/up via a Carbon hot key (no Input Monitoring permission needed).
    @MainActor static let dictate = KeyboardShortcuts.Name("dictate", default: .init(.space, modifiers: [.option]))
    /// Only enabled while a dictation is active, so Esc is untouched the rest of the time.
    @MainActor static let cancelDictation = KeyboardShortcuts.Name("cancelDictation", default: .init(.escape))
}

/// The only persistent client state besides the token file: plain UserDefaults preferences.
enum Settings {
    private static var defaults: UserDefaults { .standard }

    static var serverURL: String {
        get { defaults.string(forKey: "serverURL") ?? ServerConfig.defaultURL.absoluteString }
        set { defaults.set(newValue, forKey: "serverURL") }
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
