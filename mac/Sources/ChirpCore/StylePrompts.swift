import Foundation

/// The editable style prompts: what the server offers (`GET /v1/correction/profiles`), the last-known copy kept for
/// when it is unreachable, and the rule for which edits count. Prompt text is never logged.

/// The styles with their default prompts, and where they came from.
public struct StyleCatalog: Sendable, Equatable {
    public enum Source: String, Sendable {
        /// Fetched from the server just now.
        case live
        /// The last copy fetched, shown while the server is unreachable.
        case cached
        /// Nothing fetched yet: the built-in names, without prompt text.
        case unavailable
    }

    public var profiles: [CorrectionProfile]
    public var source: Source

    /// `profiles` is normalised: no empty or repeated ids, `custom` exactly once and last, the built-ins when empty.
    public init(profiles: [CorrectionProfile], source: Source) {
        var seen = Set<String>()
        var list = profiles.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        if list.isEmpty { list = CorrectionProfile.builtIn }
        let custom = list.first { $0.id == CorrectionProfile.customID } ?? CorrectionProfile.builtIn.first { $0.id == CorrectionProfile.customID }!
        self.profiles = list.filter { $0.id != CorrectionProfile.customID } + [custom]
        self.source = source
    }

    public static let unavailable = StyleCatalog(profiles: CorrectionProfile.builtIn, source: .unavailable)

    /// Prompts can be edited only against the live server: it states each limit and the default to reset to.
    public var canEdit: Bool { source == .live }

    public func profile(_ id: String) -> CorrectionProfile? { profiles.first { $0.id == id } }
    public func defaultPrompt(for id: String) -> String { profile(id)?.prompt ?? "" }
    public func limit(for id: String) -> Int { profile(id)?.maxPromptChars ?? CorrectionProfile.maxPromptLength }

    /// The last copy kept in `preferences`, or `.unavailable` when there is none.
    public static func cached(_ preferences: Preferences) -> StyleCatalog {
        guard let list = preferences.cachedProfiles, !list.isEmpty else { return .unavailable }
        return StyleCatalog(profiles: list, source: .cached)
    }

    /// Asks the server for its styles: a good answer is kept as the last-known copy; an unreachable or older server
    /// leaves the last-known copy (or nothing) in place, marked as not live.
    public static func refresh(_ preferences: Preferences, fetch: @Sendable () async throws -> [CorrectionProfile]) async -> StyleCatalog {
        do {
            let list = try await fetch()
            let catalog = StyleCatalog(profiles: list, source: .live)
            preferences.cachedProfiles = catalog.profiles
            return catalog
        } catch {
            return cached(preferences)
        }
    }
}

public enum StylePrompts {
    /// What to keep for text typed into a style's editor: nil when it is blank or the style's own default (so the
    /// style is not "edited" and the server's default, including its updates, applies); otherwise the text limited to
    /// `limit` characters and trimmed.
    public static func override(for text: String, default defaultPrompt: String, limit: Int) -> String? {
        let kept = CorrectionProfile.clampPrompt(text, limit: limit).trimmingCharacters(in: .whitespacesAndNewlines)
        if kept.isEmpty || kept == defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }
        return kept
    }
}

/// `GET /v1/correction/profiles`.
struct ProfilesResponse: Decodable {
    var profiles: [CorrectionProfile]
}

extension ServerConfig {
    public var profilesURL: URL { baseURL.appendingPathComponent("v1/correction/profiles") }

    /// The styles with their editable default prompts. An older server (no such route) or an empty list throws.
    public func fetchProfiles(session: URLSession = .shared) async throws -> [CorrectionProfile] {
        var req = authorized(URLRequest(url: profilesURL))
        req.timeoutInterval = 3
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let list = try decoder.decode(ProfilesResponse.self, from: data).profiles
        guard !list.isEmpty else { throw URLError(.cannotParseResponse) }
        return list
    }
}
