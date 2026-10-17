import Foundation

/// The only persistent client state besides the token file: plain UserDefaults preferences. The defaults are
/// injectable so tests use a throwaway suite.
public final class Preferences: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyInstructions()
    }

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
    /// Show what clean-up changed (the diff highlight) and keep "Use raw" in the HUD after a cleaned insertion. Off by
    /// default: the cleaned text is inserted at once, the HUD fades away, and "Use raw" lives on ⌃⌥Z and in the menu.
    public var showChangesAfterCleanup: Bool {
        get { defaults.bool(forKey: "showChangesAfterCleanup") }
        set { defaults.set(newValue, forKey: "showChangesAfterCleanup") }
    }
    /// The default clean-up style (a `correction_profiles` id).
    public var correctionProfile: String {
        get { defaults.string(forKey: "correctionProfile") ?? CorrectionProfile.defaultID }
        set { defaults.set(newValue, forKey: "correctionProfile") }
    }
    /// The prompts the user edited, by style id. A style is in here only while its prompt differs from the server's
    /// default; the others follow the server. Never logged.
    public var correctionPrompts: [String: String] {
        get { defaults.dictionary(forKey: "correctionPrompts") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "correctionPrompts") }
    }
    /// The styles with their default prompts as last fetched from the server, for showing them when it is unreachable.
    public var cachedProfiles: [CorrectionProfile]? {
        get { defaults.data(forKey: "cachedProfiles").flatMap { try? JSONDecoder().decode([CorrectionProfile].self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "cachedProfiles") }
    }
    public func isPromptEdited(_ id: String) -> Bool { correctionPrompts[id] != nil }

    /// Saves what the user typed for style `id`: kept as an edit, or dropped when it is blank or the style's default.
    /// Returns whether the style is edited afterwards. Edits need the live server's default and limit; otherwise nothing changes.
    @discardableResult
    public func setPrompt(_ text: String, for id: String, in catalog: StyleCatalog) -> Bool {
        guard catalog.canEdit else { return isPromptEdited(id) }
        var prompts = correctionPrompts
        if let kept = StylePrompts.override(for: text, default: catalog.defaultPrompt(for: id), limit: catalog.limit(for: id)) {
            prompts[id] = kept
        } else {
            prompts[id] = nil
        }
        correctionPrompts = prompts
        return prompts[id] != nil
    }

    /// Back to the server's prompt for style `id`.
    public func resetPrompt(for id: String) {
        var prompts = correctionPrompts
        prompts[id] = nil
        correctionPrompts = prompts
    }

    /// Before editable prompts, Custom's text lived in `correctionInstructions`; it is now the Custom style's prompt.
    /// Moved once: an existing Custom prompt is kept, and the old key is removed either way.
    private func migrateLegacyInstructions() {
        guard let legacy = defaults.string(forKey: "correctionInstructions") else { return }
        defaults.removeObject(forKey: "correctionInstructions")
        var prompts = correctionPrompts
        guard prompts[CorrectionProfile.customID] == nil else { return }
        let text = (CorrectionProfile.clamp(legacy) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompts[CorrectionProfile.customID] = text
        correctionPrompts = prompts
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
    /// Quiet cues when dictation starts and stops. Off by default.
    public var soundsEnabled: Bool {
        get { defaults.bool(forKey: "soundsEnabled") }
        set { defaults.set(newValue, forKey: "soundsEnabled") }
    }
    /// Which pack plays (Chirp by default; an unknown stored value falls back to it).
    public var soundPack: SoundPack {
        get { SoundPack.resolve(id: defaults.string(forKey: "soundPack")) }
        set { defaults.set(newValue.rawValue, forKey: "soundPack") }
    }
    /// The cue volume, 0…1 (60 % by default). `SoundTiming.gain(volume:)` maps it to a gain.
    public var soundVolume: Double {
        get {
            guard let v = defaults.object(forKey: "soundVolume") as? Double, v.isFinite else { return SoundTiming.defaultVolume }
            return min(max(v, 0), 1)
        }
        set { defaults.set(newValue.isFinite ? min(max(newValue, 0), 1) : SoundTiming.defaultVolume, forKey: "soundVolume") }
    }
    /// The user's own start and stop files (copies in Application Support), used by the Custom pack.
    public var customStartSound: CustomSound? {
        get { customSound(forKey: "customStartSound") }
        set { setCustomSound(newValue, forKey: "customStartSound") }
    }
    public var customStopSound: CustomSound? {
        get { customSound(forKey: "customStopSound") }
        set { setCustomSound(newValue, forKey: "customStopSound") }
    }
    public func customSound(for cue: SoundCue) -> CustomSound? { cue == .start ? customStartSound : customStopSound }

    private func customSound(forKey key: String) -> CustomSound? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(CustomSound.self, from: $0) }
    }
    private func setCustomSound(_ sound: CustomSound?, forKey key: String) {
        if let sound, let data = try? JSONEncoder().encode(sound) { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
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
                             prompts: correctionPrompts, available: available)
    }

    /// What the next `start` message asks for: the clean-up toggle is the wire `correction` flag, and the style comes
    /// from the frontmost app's rule or the default style, and the prompt goes along only when the user edited that style.
    public func startOptions(frontmostBundleID bundleID: String? = nil, available: [CorrectionProfile]? = nil) -> StartOptions {
        let style = cleanupStyle(frontmostBundleID: bundleID, available: available)
        return StartOptions(client: "mac", correction: correction, correctionProfile: style.profile,
                            correctionInstructions: style.instructions, correctionPrompt: style.prompt)
    }
}
