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
    /// Insert the raw transcript at once and swap in the cleaned text when it arrives (only for a verified AX
    /// insertion; otherwise the raw text stays). Off by default: the HUD shows the transition and inserts once.
    public var insertRawFirst: Bool {
        get { defaults.bool(forKey: "insertRawFirst") }
        set { defaults.set(newValue, forKey: "insertRawFirst") }
    }
    /// The default clean-up style (a `correction_profiles` id).
    public var correctionProfile: String {
        get { defaults.string(forKey: "correctionProfile") ?? CorrectionProfile.defaultID }
        set { defaults.set(newValue, forKey: "correctionProfile") }
    }
    /// The instructions for the `custom` style, limited to `CorrectionProfile.maxInstructionLength` characters.
    public var correctionInstructions: String {
        get { defaults.string(forKey: "correctionInstructions") ?? "" }
        set { defaults.set(CorrectionProfile.clamp(newValue) ?? "", forKey: "correctionInstructions") }
    }
    /// Frontmost app → style. A fresh install has `AppStyleRule.defaults`; once edited the stored list is the truth,
    /// including an empty one.
    public var appStyles: [AppStyleRule] {
        get {
            guard let data = defaults.data(forKey: "appStyles"),
                  let rules = try? JSONDecoder().decode([AppStyleRule].self, from: data) else { return AppStyleRule.defaults }
            return rules
        }
        set {
            var seen = Set<String>()
            let unique = newValue.filter { !$0.bundleID.isEmpty && seen.insert($0.bundleID).inserted }
            defaults.set(try? JSONEncoder().encode(unique), forKey: "appStyles")
        }
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

    /// The style for a dictation that starts in `bundleID`'s app. `available` is the server's list, when known.
    public func cleanupStyle(frontmostBundleID bundleID: String?, available: [CorrectionProfile]? = nil) -> CleanupStyle.Resolved {
        CleanupStyle.resolve(bundleID: bundleID, rules: appStyles, defaultProfile: correctionProfile,
                             instructions: correctionInstructions, available: available)
    }

    /// What the next `start` message asks for: the clean-up toggle is the wire `correction` flag, and the style comes
    /// from the frontmost app's rule or the default style.
    public func startOptions(frontmostBundleID bundleID: String? = nil, available: [CorrectionProfile]? = nil) -> StartOptions {
        let style = cleanupStyle(frontmostBundleID: bundleID, available: available)
        return StartOptions(client: "mac", correction: correction, correctionProfile: style.profile,
                            correctionInstructions: style.instructions)
    }
}
