import Foundation
import Security

/// Live Notes voice profiles (issue #18 M3, opt-in): a saved person's voice as one 256-number voiceprint, so Chirp can
/// *suggest* their name for a Person N. Voiceprints are biometric data. A session's voiceprints live in memory only;
/// a profile is saved only on the user's "Remember", only in this Mac's Keychain, and never leaves it: no file, no
/// UserDefaults, no log, no export and no request ever carries one.

/// One voice heard in this session: the duration-weighted sum of the embeddings of its settled turns of 2 s or more.
public struct Voiceprint: Equatable, Sendable {
    public private(set) var sum: [Float]
    public private(set) var seconds: TimeInterval

    public init(sum: [Float] = [], seconds: TimeInterval = 0) {
        self.sum = sum
        self.seconds = seconds
    }

    /// `embedding` heard for `seconds`.
    public mutating func add(_ embedding: [Float], seconds: TimeInterval) {
        guard !embedding.isEmpty, seconds > 0, embedding.allSatisfy(\.isFinite) else { return }
        if sum.isEmpty { sum = [Float](repeating: 0, count: embedding.count) }
        guard sum.count == embedding.count else { return }
        let w = Float(seconds)
        for i in sum.indices { sum[i] += embedding[i] * w }
        self.seconds += seconds
    }

    public mutating func add(_ other: Voiceprint) {
        guard !other.sum.isEmpty else { return }
        if sum.isEmpty { self = other; return }
        guard sum.count == other.sum.count else { return }
        for i in sum.indices { sum[i] += other.sum[i] }
        seconds += other.seconds
    }

    /// The unit-length mean voice.
    public var centroid: [Float] { Self.normalized(sum) }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        let x = normalized(a), y = normalized(b)
        return zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

/// A remembered voice: what one Keychain item holds.
public struct VoiceProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// The unit-length voiceprint (256 numbers).
    public var embedding: [Float]
    /// The embedding model it came from (`VoiceModelInfo.id`): voiceprints are never compared across models.
    public var model: String
    /// Seconds of speech behind it.
    public var seconds: TimeInterval
    public var created: Date
    public var updated: Date

    public init(id: UUID = UUID(), name: String, embedding: [Float], model: String, seconds: TimeInterval,
                created: Date = Date(), updated: Date? = nil) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.model = model
        self.seconds = seconds
        self.created = created
        self.updated = updated ?? created
    }
}

/// Where profiles are kept. The app's is the Keychain; tests use memory.
public protocol VoiceProfileStore: Sendable {
    func load() throws -> [VoiceProfile]
    func save(_ profile: VoiceProfile) throws
    func delete(_ id: UUID) throws
    func deleteAll() throws
}

public final class MemoryVoiceProfileStore: VoiceProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: VoiceProfile] = [:]

    public init(_ profiles: [VoiceProfile] = []) { for p in profiles { items[p.id] = p } }

    public func load() throws -> [VoiceProfile] { lock.withLock { items.values.sorted { $0.created < $1.created } } }
    public func save(_ profile: VoiceProfile) throws { lock.withLock { items[profile.id] = profile } }
    public func delete(_ id: UUID) throws { _ = lock.withLock { items.removeValue(forKey: id) } }
    public func deleteAll() throws { lock.withLock { items.removeAll() } }
}

/// One generic-password item per profile (service "Chirp Voice Profile", account = its id), never synchronizable.
/// It goes in the data-protection keychain as `WhenUnlockedThisDeviceOnly` when the build may use it; a build without
/// a keychain entitlement (Chirp's self-signed one) gets -34018 there and uses this Mac's login keychain instead,
/// which iCloud Keychain never syncs.
public struct KeychainVoiceProfileStore: VoiceProfileStore {
    public static let service = "Chirp Voice Profile"
    let service: String

    public init(service: String = KeychainVoiceProfileStore.service) { self.service = service }

    public enum KeychainError: Error, Equatable { case status(OSStatus) }

    /// Base attributes for one keychain (data protection or login).
    private func query(_ dataProtection: Bool, _ extra: [String: Any] = [:]) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: false]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q.merging(extra) { $1 }
    }

    /// The keychains to touch: data protection first, then (always) the login keychain.
    private var keychains: [Bool] { [true, false] }

    public func load() throws -> [VoiceProfile] {
        var out: [UUID: VoiceProfile] = [:]
        for dp in keychains {
            // The login keychain returns data for one item at a time: list the accounts, then read each.
            var result: AnyObject?
            let status = SecItemCopyMatching(query(dp, [kSecMatchLimit as String: kSecMatchLimitAll,
                                                        kSecReturnAttributes as String: true]) as CFDictionary, &result)
            guard status == errSecSuccess else {
                if status == errSecItemNotFound || status == errSecMissingEntitlement { continue }
                throw KeychainError.status(status)
            }
            for account in ((result as? [[String: Any]]) ?? []).compactMap({ $0[kSecAttrAccount as String] as? String }) {
                var data: AnyObject?
                guard SecItemCopyMatching(query(dp, [kSecAttrAccount as String: account, kSecMatchLimit as String: kSecMatchLimitOne,
                                                     kSecReturnData as String: true]) as CFDictionary, &data) == errSecSuccess,
                      let data = data as? Data, let p = try? JSONDecoder().decode(VoiceProfile.self, from: data), out[p.id] == nil
                else { continue }
                out[p.id] = p
            }
        }
        return out.values.sorted { $0.created < $1.created }
    }

    public func save(_ profile: VoiceProfile) throws {
        let data = try JSONEncoder().encode(profile)
        let account = profile.id.uuidString
        for dp in keychains {
            let match = query(dp, [kSecAttrAccount as String: account])
            var status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query(dp, [kSecAttrAccount as String: account, kSecValueData as String: data,
                                               kSecAttrLabel as String: "Chirp voice profile",
                                               kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) as CFDictionary, nil)
            }
            if status == errSecMissingEntitlement { continue }
            guard status == errSecSuccess else { throw KeychainError.status(status) }
            return
        }
    }

    public func delete(_ id: UUID) throws { try remove(query: [kSecAttrAccount as String: id.uuidString]) }
    public func deleteAll() throws { try remove(query: [:]) }

    private func remove(query extra: [String: Any]) throws {
        for dp in keychains {
            let status = SecItemDelete(query(dp, extra) as CFDictionary)
            guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else { throw KeychainError.status(status) }
        }
    }
}

/// Matching a session's voices to profiles. Only ever a suggestion: the user confirms a name.
public enum VoiceMatch {
    /// The cosine similarity a suggestion needs (from the bench, docs/bench.md "Voice profiles")…
    public static let threshold: Float = 0.70
    /// …and its lead over the next-best profile.
    public static let margin: Float = 0.10
    /// Seconds of a person's speech before Chirp suggests anything for them.
    public static let minSeconds: TimeInterval = 10
    /// Seconds of speech "Remember this voice" needs.
    public static let enrolSeconds: TimeInterval = 20

    /// For each person with enough speech, the profile (of `model`) whose voice is at least `threshold` alike and
    /// `margin` ahead of every other. A profile goes to at most one person (the closest).
    public static func suggest(_ voices: [Int: Voiceprint], profiles: [VoiceProfile], model: String,
                               threshold: Float = threshold, margin: Float = margin,
                               minSeconds: TimeInterval = minSeconds) -> [Int: UUID] {
        let usable = profiles.filter { $0.model == model }
        var best: [UUID: (person: Int, score: Float)] = [:]
        for (person, voice) in voices.sorted(by: { $0.key < $1.key }) where voice.seconds >= minSeconds {
            let centroid = voice.centroid
            let scores = usable.map { (id: $0.id, score: Voiceprint.cosine(centroid, $0.embedding)) }.sorted { $0.score > $1.score }
            guard let top = scores.first, top.score >= threshold else { continue }
            if scores.count > 1, top.score - scores[1].score < margin { continue }
            if let held = best[top.id], held.score >= top.score { continue }
            best[top.id] = (person, top.score)
        }
        return Dictionary(best.map { ($0.value.person, $0.key) }, uniquingKeysWith: { a, _ in a })
    }
}

/// The voice-embedding model, as Settings and the consent prompt describe it.
public protocol VoiceModelStore: Sendable {
    /// Which model a profile came from ("wespeaker_v2@df2625a").
    var modelID: String { get }
    var sizeText: String { get }
    func isDownloaded() -> Bool
    func hasFiles() -> Bool
    /// Only `download: true`, after the user's Download, may use the network.
    func load(download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> any VoiceEmbedder
    func remove() throws
}

/// No voice model (tests, and anything without `ChirpSpeakers`): never downloaded, never loads.
public struct UnavailableVoiceModelStore: VoiceModelStore {
    public init() {}
    public var modelID: String { "none" }
    public var sizeText: String { "" }
    public func isDownloaded() -> Bool { false }
    public func hasFiles() -> Bool { false }
    public func load(download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> any VoiceEmbedder {
        throw CancellationError()
    }
    public func remove() throws {}
}

/// Turns up to 10 s of one voice (16 kHz mono floats) into a unit-length 256-number embedding.
public protocol VoiceEmbedder: AnyObject, Sendable {
    func embedding(_ samples: [Float]) throws -> [Float]
}

/// The only voice-profile log line: counts, never a name or a number of a voiceprint.
public enum VoiceLog {
    public static func profiles(saved: Int, suggestions: Int) -> String { "notes voices saved=\(saved) suggestions=\(suggestions)" }
}
