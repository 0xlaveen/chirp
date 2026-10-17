import Foundation

/// A clean-up style the server offers (`correction_profiles` in the authenticated health response).
public struct CorrectionProfile: Codable, Sendable, Equatable, Identifiable {
    public static let defaultID = "default"
    public static let customID = "custom"
    /// What the server accepts in `correction_instructions`.
    public static let maxInstructionLength = 2000

    public var id: String
    public var name: String
    public var description: String
    /// The style may restructure the text (bullets), so the HUD warns and the server relaxes its word-retention guard.
    public var rewrites: Bool

    public init(id: String, name: String, description: String = "", rewrites: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.rewrites = rewrites
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? Self.displayName(for: id)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        rewrites = try c.decodeIfPresent(Bool.self, forKey: .rewrites) ?? false
    }

    /// The built-in styles, for choosing a style while the server is unreachable or predates profiles.
    public static let builtIn: [CorrectionProfile] = [
        CorrectionProfile(id: "default", name: "Default", description: "Conservative: fixes punctuation and obvious slips."),
        CorrectionProfile(id: "chat", name: "Chat", description: "Casual: lowercase is fine, short messages skip the period."),
        CorrectionProfile(id: "email", name: "Email", description: "Polished, complete sentences. Adds nothing."),
        CorrectionProfile(id: "code", name: "Code", description: "Literal: keeps identifiers, symbols and casing."),
        CorrectionProfile(id: "notes", name: "Notes", description: "Tidies lists into short lines or bullets.", rewrites: true),
        CorrectionProfile(id: "custom", name: "Custom", description: "Your own instructions."),
    ]

    /// The name to show for an id the server did not describe.
    public static func displayName(for id: String) -> String {
        builtIn.first { $0.id == id }?.name ?? id.prefix(1).uppercased() + id.dropFirst()
    }

    /// The styles to offer: the server's list when it has one, else the built-ins. `custom` is always last, exactly once.
    public static func offered(by health: Health?) -> [CorrectionProfile] {
        var list = health?.correctionProfiles ?? builtIn
        if list.isEmpty { list = builtIn }
        let custom = list.first { $0.id == customID } ?? builtIn.first { $0.id == customID }!
        return list.filter { $0.id != customID } + [custom]
    }

    /// The chip text for style `id`: the server's name for it, else the built-in one.
    public static func name(for id: String, in health: Health?) -> String {
        health?.correctionProfiles?.first { $0.id == id }?.name ?? displayName(for: id)
    }

    /// `text` limited to `maxInstructionLength` characters (grapheme clusters, so an emoji is never cut in half).
    /// Nil stays nil.
    public static func clamp(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.count > maxInstructionLength ? String(text.prefix(maxInstructionLength)) : text
    }
}

/// A frontmost app and the style used when dictation starts in it.
public struct AppStyleRule: Codable, Sendable, Equatable, Identifiable {
    public var bundleID: String
    public var profile: String
    public var id: String { bundleID }

    public init(bundleID: String, profile: String) {
        self.bundleID = bundleID
        self.profile = profile
    }

    /// What a fresh install ships with.
    public static let defaults: [AppStyleRule] = [
        ("com.tinyspeck.slackmacgap", "chat"), ("com.apple.MobileSMS", "chat"), ("com.hnc.Discord", "chat"),
        ("net.whatsapp.WhatsApp", "chat"),
        ("com.apple.mail", "email"), ("com.microsoft.Outlook", "email"), ("com.superhuman.electron", "email"),
        ("com.apple.Terminal", "code"), ("com.googlecode.iterm2", "code"), ("com.mitchellh.ghostty", "code"),
        ("com.microsoft.VSCode", "code"), ("com.todesktop.230313mzl4w4u92", "code"), ("com.apple.dt.Xcode", "code"),
        ("dev.zed.Zed", "code"),
        ("com.apple.Notes", "notes"), ("md.obsidian", "notes"), ("notion.id", "notes"),
    ].map { AppStyleRule(bundleID: $0.0, profile: $0.1) }
}

/// Which style a dictation uses. Pure, so it is unit-tested.
public enum CleanupStyle {
    public struct Resolved: Sendable, Equatable {
        public var profile: String
        /// Only for `custom`.
        public var instructions: String?
    }

    /// The frontmost app's rule wins over the default style. A style the server does not list falls back to `default`
    /// (when the server lists any), and `custom` without instructions falls back to `default` too.
    public static func resolve(bundleID: String?, rules: [AppStyleRule], defaultProfile: String, instructions: String,
                               available: [CorrectionProfile]? = nil) -> Resolved {
        var id = defaultProfile
        if let bundleID, let rule = rules.first(where: { $0.bundleID == bundleID }) { id = rule.profile }
        if let available, !available.isEmpty, !available.contains(where: { $0.id == id }) { id = CorrectionProfile.defaultID }
        if id == CorrectionProfile.customID {
            let text = CorrectionProfile.clamp(instructions.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            if text.isEmpty { return Resolved(profile: CorrectionProfile.defaultID, instructions: nil) }
            return Resolved(profile: id, instructions: text)
        }
        return Resolved(profile: id, instructions: nil)
    }
}
