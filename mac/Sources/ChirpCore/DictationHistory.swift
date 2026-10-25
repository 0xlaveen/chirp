import CryptoKit
import Foundation
import Observation
import Security

/// One committed dictation, as kept in the local history: what was inserted, the raw transcript when clean-up changed
/// it, the app it went to, when, how long it was and which style cleaned it. Never logged: `description` is redacted.
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    public var id: UUID
    public var date: Date
    /// What went into the field (after "Use raw", the raw transcript).
    public var text: String
    /// The raw transcript, only when clean-up changed it.
    public var raw: String?
    /// The app that was frontmost when the dictation started.
    public var bundleID: String?
    public var appName: String?
    /// Seconds of audio.
    public var duration: TimeInterval
    /// The clean-up style id, when clean-up ran.
    public var style: String?

    public init(id: UUID = UUID(), date: Date, text: String, raw: String? = nil, bundleID: String? = nil, appName: String? = nil,
                duration: TimeInterval = 0, style: String? = nil) {
        self.id = id
        self.date = date
        self.text = text
        self.raw = raw == text ? nil : raw
        self.bundleID = bundleID
        self.appName = appName
        self.duration = duration
        self.style = style
    }

    /// Clean-up changed the words: the row shows a "cleaned" badge and the detail a diff.
    public var cleaned: Bool { raw != nil }
    /// What the History window calls the app.
    public var appTitle: String { appName ?? bundleID ?? "Unknown app" }

    public var description: String { "HistoryEntry(<redacted>)" }
    public var debugDescription: String { description }
}

/// How long dictation history is kept (Settings → Dictation → History). 30 days by default.
public enum HistoryRetention: String, CaseIterable, Codable, Sendable {
    case oneDay, sevenDays, thirtyDays, ninetyDays, forever

    public static let `default` = HistoryRetention.thirtyDays

    public var days: Int? {
        switch self {
        case .oneDay: 1
        case .sevenDays: 7
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .forever: nil
        }
    }

    public var title: String {
        switch self {
        case .oneDay: "1 day"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        case .forever: "Forever"
        }
    }
}

/// What history keeps, and what it never does. Pure, so it is unit-tested.
public enum HistoryPolicy {
    /// Longest dictation kept (characters); anything longer is not recorded.
    public static let maxCharacters = 20_000
    /// Most entries kept, whatever the retention; the oldest go first.
    public static let maxEntries = 10_000

    /// Password managers: never recorded unless the user takes them off the list.
    public static let defaultExcludedApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.Passwords",
        "com.apple.keychainaccess",
    ]

    /// Whether this insertion goes into the history. Only text that reached the user (inserted, written but
    /// unverified, or copied) counts; a secure field, a refused insertion, an excluded app or an empty or oversized
    /// text never does. A cancelled dictation never gets here.
    public static func shouldRecord(enabled: Bool, outcome: InsertionOutcome, secureField: Bool, bundleID: String?,
                                    excluded: [String], text: String) -> Bool {
        guard enabled, !secureField, outcome != .refusedSecure else { return false }
        if let bundleID, excluded.contains(bundleID) { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxCharacters
    }
}

/// Where the history's key lives. The app's is the Keychain; tests use memory.
public protocol HistoryKeyStore: Sendable {
    /// The key, or nil when there is none.
    func read() throws -> Data?
    func write(_ key: Data) throws
    func delete() throws
}

public final class MemoryHistoryKeyStore: HistoryKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    public init(key: Data? = nil) { self.key = key }
    public func read() throws -> Data? { lock.withLock { key } }
    public func write(_ key: Data) throws { lock.withLock { self.key = key } }
    public func delete() throws { lock.withLock { key = nil } }
}

/// The history's 256-bit key as one generic-password item, never synchronizable: the data-protection keychain as
/// `WhenUnlockedThisDeviceOnly` when the build may use it, else (a self-signed build) this Mac's login keychain,
/// which iCloud Keychain never syncs. The same rules as `KeychainVoiceProfileStore`.
public struct KeychainHistoryKeyStore: HistoryKeyStore {
    public static let service = "Chirp Dictation History"
    let service: String
    let account = "history-key-v1"

    public init(service: String = KeychainHistoryKeyStore.service) { self.service = service }

    public enum KeychainError: Error, Equatable { case status(OSStatus) }

    private func query(_ dataProtection: Bool, _ extra: [String: Any] = [:]) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q.merging(extra) { $1 }
    }

    public func read() throws -> Data? {
        for dp in [true, false] {
            var data: AnyObject?
            let status = SecItemCopyMatching(query(dp, [kSecMatchLimit as String: kSecMatchLimitOne,
                                                        kSecReturnData as String: true]) as CFDictionary, &data)
            if status == errSecSuccess, let data = data as? Data { return data }
            guard [errSecItemNotFound, errSecMissingEntitlement].contains(status) else { throw KeychainError.status(status) }
        }
        return nil
    }

    public func write(_ key: Data) throws {
        for dp in [true, false] {
            var status = SecItemUpdate(query(dp) as CFDictionary, [kSecValueData as String: key] as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query(dp, [kSecValueData as String: key, kSecAttrLabel as String: "Chirp dictation history key",
                                               kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) as CFDictionary, nil)
            }
            if status == errSecMissingEntitlement { continue }
            guard status == errSecSuccess else { throw KeychainError.status(status) }
            return
        }
    }

    public func delete() throws {
        for dp in [true, false] {
            let status = SecItemDelete(query(dp) as CFDictionary)
            guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else { throw KeychainError.status(status) }
        }
    }
}

extension NotesJournalCodec {
    /// AES-GCM with `key`; `context` is authenticated with every file so a sealed file cannot be swapped for another.
    public static func aesGCM(key: SymmetricKey, context: String) -> NotesJournalCodec {
        let aad = Data(context.utf8)
        return NotesJournalCodec(
            seal: { plain in
                guard let combined = try AES.GCM.seal(plain, using: key, authenticating: aad).combined else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return combined
            },
            open: { sealed in try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad) })
    }
}

public enum DictationHistoryError: Error, Equatable { case keyUnavailable }

/// The sealed dictation history in `~/Library/Application Support/Chirp/History`: one AES-GCM file per day
/// (`yyyy-MM-dd.sealed`, a JSON array of entries), written atomically with owner-only permissions, never indexed by
/// Spotlight. The key is in the Keychain; a file that no longer opens (the key was lost) is discarded, never repaired.
/// Serial disk access and sealing run on this actor.
public actor DictationHistoryStore {
    public nonisolated let directory: URL
    private let keys: HistoryKeyStore
    private let now: @Sendable () -> Date
    /// Day file name → its entries, oldest first, once loaded.
    private var days: [String: [HistoryEntry]]?
    private var cachedKey: SymmetricKey?
    static let suffix = ".sealed"
    static let schemaContext = "chirp.history.v1:"

    public static var defaultDirectory: URL {
        NotesJournalStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("History", isDirectory: true)
    }

    public init(directory: URL = DictationHistoryStore.defaultDirectory, keys: HistoryKeyStore = KeychainHistoryKeyStore(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.keys = keys
        self.now = now
    }

    /// The file a dictation at `date` belongs to (UTC days, so a time-zone change never splits one file in two).
    nonisolated static func dayName(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0) + suffix
    }

    private func key(create: Bool) throws -> SymmetricKey? {
        if let cachedKey { return cachedKey }
        if let data = try keys.read(), data.count == 32 {
            cachedKey = SymmetricKey(data: data)
            return cachedKey
        }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        try keys.write(key.withUnsafeBytes { Data($0) })
        cachedKey = key
        return key
    }

    private func codec(_ key: SymmetricKey, _ name: String) -> NotesJournalCodec { .aesGCM(key: key, context: Self.schemaContext + name) }

    private func dayFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(Self.suffix + ".tmp") { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        return names.filter { $0.hasSuffix(Self.suffix) }
    }

    /// Opens every day file. A missing key with files on disk means they can never be read again: they are deleted.
    /// A Keychain error (locked, denied) throws and leaves everything as it is.
    private func load() throws {
        guard days == nil else { return }
        let files = dayFiles()
        guard !files.isEmpty else { days = [:]; return }
        guard let key = try key(create: false) else {
            chirpLog.info("history key missing files=\(files.count, privacy: .public): discarded")
            for name in files { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
            days = [:]
            return
        }
        var loaded: [String: [HistoryEntry]] = [:]
        for name in files {
            let url = directory.appendingPathComponent(name)
            guard let sealed = try? Data(contentsOf: url) else { continue }
            guard let plain = try? codec(key, name).open(sealed),
                  let entries = try? JSONDecoder().decode([HistoryEntry].self, from: plain) else {
                chirpLog.info("history file unreadable bytes=\(sealed.count, privacy: .public): discarded")
                try? FileManager.default.removeItem(at: url)
                continue
            }
            loaded[name] = entries
        }
        days = loaded
    }

    private func save(_ name: String) throws {
        let entries = days?[name] ?? []
        let url = directory.appendingPathComponent(name)
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let key = try key(create: true) else { throw DictationHistoryError.keyUnavailable }
        try prepareDirectory()
        let plain = try JSONEncoder().encode(entries)
        try NotesAtomicFile.write(try codec(key, name).seal(plain), to: url)
    }

    /// `0700`, and a marker that keeps Spotlight out.
    private func prepareDirectory() throws {
        try NotesAtomicFile.directory(directory)
        let marker = directory.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path) {
            FileManager.default.createFile(atPath: marker.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
    }

    /// Newest first.
    public func entries() throws -> [HistoryEntry] {
        try load()
        return (days ?? [:]).values.flatMap { $0 }.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
    }

    public func entry(_ id: UUID) throws -> HistoryEntry? {
        try load()
        return days?.values.lazy.compactMap { $0.first { $0.id == id } }.first
    }

    /// Adds `entry` (or puts a deleted one back, for Undo), then keeps the newest `HistoryPolicy.maxEntries`.
    public func add(_ entry: HistoryEntry) throws {
        try load()
        let name = Self.dayName(entry.date)
        var list = (days?[name] ?? []).filter { $0.id != entry.id }
        list.append(entry)
        list.sort { $0.date < $1.date }
        days?[name] = list
        try save(name)
        try trim()
    }

    /// Changes one entry in place ("Use raw" replaced the insertion); false when it is gone.
    @discardableResult
    public func update(_ id: UUID, _ change: @Sendable (inout HistoryEntry) -> Void) throws -> Bool {
        try load()
        for (name, list) in days ?? [:] {
            guard let i = list.firstIndex(where: { $0.id == id }) else { continue }
            var entry = list[i]
            change(&entry)
            entry.id = id
            days?[name]?[i] = entry
            try save(name)
            return true
        }
        return false
    }

    /// Removes one entry and returns it (for Undo).
    @discardableResult
    public func delete(_ id: UUID) throws -> HistoryEntry? {
        try load()
        for (name, list) in days ?? [:] {
            guard let entry = list.first(where: { $0.id == id }) else { continue }
            days?[name] = list.filter { $0.id != id }
            try save(name)
            return entry
        }
        return nil
    }

    /// Everything goes: the files and the key, so nothing left behind could be opened again.
    public func clear() throws {
        for name in dayFiles() { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        days = [:]
        cachedKey = nil
        try keys.delete()
    }

    /// Drops entries older than `retention`; returns how many went.
    @discardableResult
    public func prune(retention: HistoryRetention) throws -> Int {
        guard let limit = retention.days else { return 0 }
        try load()
        let cutoff = now().addingTimeInterval(-Double(limit) * 86400)
        var removed = 0
        for (name, list) in days ?? [:] {
            let kept = list.filter { $0.date >= cutoff }
            guard kept.count != list.count else { continue }
            removed += list.count - kept.count
            days?[name] = kept
            try save(name)
        }
        return removed
    }

    private func trim() throws {
        let all = try entries()
        guard all.count > HistoryPolicy.maxEntries else { return }
        for entry in all.dropFirst(HistoryPolicy.maxEntries) { try delete(entry.id) }
    }

    /// Entries whose text, raw text or app match `query` (case- and diacritic-insensitive), newest first.
    public func search(_ query: String) throws -> [HistoryEntry] {
        let all = try entries()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { HistorySearch.matches($0, q) }
    }
}

public enum HistorySearch {
    public static func matches(_ entry: HistoryEntry, _ query: String) -> Bool {
        [entry.text, entry.raw ?? "", entry.appTitle].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// The dictation history the app and its windows observe. Every disk read, write and seal runs on `store`'s actor;
/// `entries` is the newest-first list. Nothing here is logged.
@MainActor @Observable public final class DictationHistory {
    public let store: DictationHistoryStore
    public private(set) var entries: [HistoryEntry] = []
    /// The last load or write failed (the Keychain was locked or denied): the window says so instead of "No dictations".
    public private(set) var unavailable = false
    /// Called after every change of `entries`.
    @ObservationIgnored public var onChange: (() -> Void)?

    public init(store: DictationHistoryStore = DictationHistoryStore()) { self.store = store }

    public func reload() async {
        do {
            entries = try await store.entries()
            unavailable = false
        } catch {
            unavailable = true
            chirpLog.info("history load failed")
        }
        onChange?()
    }

    /// Keeps a committed dictation; the caller already checked `HistoryPolicy.shouldRecord`.
    public func record(_ entry: HistoryEntry) async {
        do { try await store.add(entry) } catch { chirpLog.info("history write failed") }
        await reload()
    }

    /// "Use raw" put the raw transcript in the field: the entry keeps what is really there now.
    public func usedRaw(_ id: UUID) async {
        _ = try? await store.update(id) { entry in
            guard let raw = entry.raw else { return }
            entry.text = raw
            entry.raw = nil
        }
        await reload()
    }

    /// Deletes one entry and returns it, for Undo.
    @discardableResult
    public func delete(_ id: UUID) async -> HistoryEntry? {
        let removed = try? await store.delete(id)
        await reload()
        return removed ?? nil
    }

    public func restore(_ entry: HistoryEntry) async {
        try? await store.add(entry)
        await reload()
    }

    public func clear() async {
        do { try await store.clear() } catch { chirpLog.info("history clear failed") }
        await reload()
    }

    public func maintain(retention: HistoryRetention) async {
        _ = try? await store.prune(retention: retention)
        await reload()
    }

    /// The newest `limit` entries, for the menu's Recent submenu.
    public func recent(_ limit: Int = 3) -> [HistoryEntry] { Array(entries.prefix(limit)) }
}
