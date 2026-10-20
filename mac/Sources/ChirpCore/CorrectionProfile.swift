import Foundation

/// A clean-up style the server offers (`correction_profiles` in the authenticated health response). The richer
/// `GET /v1/correction/profiles` also carries the editable `prompt` and its `max_prompt_chars` limit.
public struct CorrectionProfile: Codable, Sendable, Equatable, Identifiable {
    public static let defaultID = "default"
    public static let customID = "custom"
    /// The hidden Live Notes segment style (fillers, stutters and restarts removed); never listed or picked. Only sent to
    /// a server whose health has `notes_correction`.
    public static let liveNotesID = "live_notes"
    /// What the server accepts in `correction_instructions`.
    public static let maxInstructionLength = 2000
    /// What the server accepts in `correction_prompt`, and the limit assumed until it states one.
    public static let maxPromptLength = 4000

    public var id: String
    public var name: String
    public var description: String
    /// The style may restructure the text (bullets), so the HUD warns and the server relaxes its word-retention guard.
    public var rewrites: Bool
    /// The style's editable default prompt: only the style part, never the server's fixed safety wrapper. Empty in the
    /// health response (which carries no prompt text) and for `custom`. Never logged.
    public var prompt: String
    /// The longest prompt the server accepts for this style.
    public var maxPromptChars: Int

    public init(id: String, name: String, description: String = "", rewrites: Bool = false, prompt: String = "",
                maxPromptChars: Int = CorrectionProfile.maxPromptLength) {
        self.id = id
        self.name = name
        self.description = description
        self.rewrites = rewrites
        self.prompt = prompt
        self.maxPromptChars = maxPromptChars
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? Self.displayName(for: id)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        rewrites = try c.decodeIfPresent(Bool.self, forKey: .rewrites) ?? false
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        let limit = try c.decodeIfPresent(Int.self, forKey: .maxPromptChars) ?? Self.maxPromptLength
        maxPromptChars = limit > 0 ? limit : Self.maxPromptLength
    }

    /// The built-in styles, for choosing a style while the server is unreachable or predates profiles.
    public static let builtIn: [CorrectionProfile] = [
        CorrectionProfile(id: "default", name: "Default", description: "Conservative: fixes punctuation and obvious slips."),
        CorrectionProfile(id: "chat", name: "Chat", description: "Casual: lowercase is fine, short messages skip the period."),
        CorrectionProfile(id: "email", name: "Email", description: "Polished, complete sentences. Adds nothing."),
        CorrectionProfile(id: "code", name: "Code", description: "Literal: keeps identifiers, symbols and casing."),
        CorrectionProfile(id: "notes", name: "Notes", description: "Tidies lists into short lines or bullets.", rewrites: true),
        CorrectionProfile(id: "custom", name: "Custom", description: "Your own prompt."),
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

    /// `text` limited to `maxInstructionLength` Unicode scalars (Python server character count), preserving whole graphemes.
    /// Nil stays nil.
    public static func clamp(_ text: String?) -> String? {
        guard let text else { return nil }
        return clampPrompt(text, limit: maxInstructionLength)
    }

    /// `text` limited to `limit` Unicode scalars, preserving whole graphemes.
    public static func clampPrompt(_ text: String, limit: Int = maxPromptLength) -> String {
        let limit = max(0, limit)
        var used = 0
        return String(text.prefix { character in
            let count = character.unicodeScalars.count
            guard used + count <= limit else { return false }
            used += count
            return true
        })
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
    public enum Source: Sendable, Equatable {
        /// The frontmost app has a rule.
        case appRule
        /// No rule: the default style.
        case defaultStyle
        /// The chosen style is not usable (the server does not list it, or Custom has no prompt): `default` instead.
        case fallback
    }

    public struct Resolved: Sendable, Equatable {
        public var profile: String
        /// Only for `custom`: the same text as `prompt`, for servers that predate `correction_prompt`.
        public var instructions: String?
        /// The user's edited prompt for the style; nil when it was not edited, so the server's default applies.
        public var prompt: String?
        public var source: Source

        public init(profile: String, instructions: String? = nil, prompt: String? = nil, source: Source = .defaultStyle) {
            self.profile = profile
            self.instructions = instructions
            self.prompt = prompt
            self.source = source
        }
    }

    /// The frontmost app's rule wins over the default style. A style the server does not list falls back to `default`
    /// (when the server lists any), and `custom` without a prompt falls back to `default` too. `prompts` holds the
    /// edited prompts by style id (see `StylePrompts`).
    public static func resolve(bundleID: String?, rules: [AppStyleRule], defaultProfile: String, prompts: [String: String],
                               available: [CorrectionProfile]? = nil) -> Resolved {
        var id = defaultProfile
        var source = Source.defaultStyle
        if let bundleID, let rule = rules.first(where: { $0.bundleID == bundleID }) { id = rule.profile; source = .appRule }
        if let available, !available.isEmpty, !available.contains(where: { $0.id == id }) {
            id = CorrectionProfile.defaultID
            source = .fallback
        }
        func edited(_ id: String) -> String? {
            let limit = available?.first { $0.id == id }?.maxPromptChars ?? CorrectionProfile.maxPromptLength
            let text = CorrectionProfile.clampPrompt(prompts[id] ?? "", limit: limit).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if id == CorrectionProfile.customID {
            guard let text = edited(id) else {
                return Resolved(profile: CorrectionProfile.defaultID, prompt: edited(CorrectionProfile.defaultID), source: .fallback)
            }
            return Resolved(profile: id, instructions: CorrectionProfile.clamp(text), prompt: text, source: source)
        }
        return Resolved(profile: id, prompt: edited(id), source: source)
    }

    /// What the Per-app "Test" button says about `appName` (nil: the app is not known) and the style it resolved to.
    public static func testSummary(appName: String?, resolved: Resolved, styleName: String) -> String {
        let app = appName ?? "This app"
        var text: String
        switch resolved.source {
        case .appRule: text = "\(app) → \(styleName) style (app rule)."
        case .defaultStyle: text = "\(app) → \(styleName) style (no rule: the default style)."
        case .fallback: text = "\(app) → \(styleName) style (the chosen style is not available)."
        }
        if resolved.prompt != nil { text += " Uses your edited prompt." }
        return text
    }
}
