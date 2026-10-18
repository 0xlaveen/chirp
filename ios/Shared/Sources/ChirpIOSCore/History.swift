import Foundation

public enum HistoryRetention: String, Codable, Sendable, CaseIterable {
    case day, week, month
    public var seconds: TimeInterval { switch self { case .day: 86_400; case .week: 604_800; case .month: 2_592_000 } }
}
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var text: String
    public var raw: String?
    public var corrected: Bool
    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String, raw: String? = nil, corrected: Bool = false) {
        self.id = id; self.createdAt = createdAt; self.text = text; self.raw = raw; self.corrected = corrected
    }
}
public struct HistorySettings: Codable, Sendable, Equatable {
    public var enabled = false
    public var retention: HistoryRetention = .week
    public var generation = UUID()
    public init() {}
}

/// Disk state is authoritative under the same process-safe lock as Keychain changes. No cached enabled flag/key.
/// A racing record either precedes disable (then is deleted) or follows it (then cannot recreate a key/file).
public final class HistoryStore: Sendable {
    public static let keyAccount = "history.aes.v1"
    private let sealed: SealedStorage
    private let now: @Sendable () -> Date
    private let maximumBytes = 4 * 1_048_576
    public init(root: URL, secrets: any SecretStore, now: @escaping @Sendable () -> Date = { Date() }) throws {
        sealed = SealedStorage(files: try ProtectedFiles(root: root.appendingPathComponent("history", isDirectory: true)),
                               secrets: secrets, account: Self.keyAccount)
        self.now = now
    }
    private func settingsLocked() throws -> HistorySettings {
        try sealed.files.load(HistorySettings.self, "settings.json", max: 4096) ?? HistorySettings()
    }
    public func settings() throws -> HistorySettings { try sealed.files.transaction { try settingsLocked() } }
    public func setEnabled(_ enabled: Bool) throws {
        try sealed.files.transaction {
            var settings = try settingsLocked()
            settings.enabled = enabled; settings.generation = UUID()
            // Persist the disabled fence BEFORE deleting. A failed delete still blocks every future writer.
            try sealed.files.save(settings, "settings.json", max: 4096)
            if !enabled {
                try sealed.files.remove("entries.sealed")
                try sealed.secrets.delete(account: Self.keyAccount)
            }
        }
    }
    public func setRetention(_ retention: HistoryRetention) throws {
        try sealed.files.transaction {
            var settings = try settingsLocked(); settings.retention = retention
            try sealed.files.save(settings, "settings.json", max: 4096)
            if settings.enabled { try save(prune(try load(), settings: settings)) }
        }
    }
    @discardableResult
    public func record(text: String, raw: String? = nil, corrected: Bool = false) throws -> HistoryEntry? {
        try record(HistoryEntry(createdAt: now(), text: text, raw: raw, corrected: corrected))
    }
    @discardableResult
    public func record(_ entry: HistoryEntry) throws -> HistoryEntry? {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard entry.text.utf8.count <= 65_536, (entry.raw?.utf8.count ?? 0) <= 65_536 else { throw CoreError.oversized }
        return try sealed.files.transaction {
            let settings = try settingsLocked()
            guard settings.enabled else { return nil }
            guard entry.createdAt <= now(), entry.createdAt > now().addingTimeInterval(-settings.retention.seconds) else { return nil }
            var entries = try prune(load(), settings: settings)
            guard !entries.contains(where: { $0.id == entry.id }) else { throw CoreError.replay }
            entries.append(entry)
            entries = prune(entries, settings: settings)
            while try JSONEncoder().encode(entries).count + 28 > maximumBytes { entries.removeFirst() }
            try save(entries)
            return entry
        }
    }
    public func entries() throws -> [HistoryEntry] {
        try sealed.files.transaction {
            let settings = try settingsLocked()
            guard settings.enabled else {
                try sealed.files.remove("entries.sealed"); try sealed.secrets.delete(account: Self.keyAccount)
                return []
            }
            let entries = try prune(load(), settings: settings)
            if entries.isEmpty { try sealed.files.remove("entries.sealed") } else { try save(entries) }
            return entries.reversed()
        }
    }
    public func delete(id: UUID) throws {
        try sealed.files.transaction {
            guard try settingsLocked().enabled else { return }
            try save(load().filter { $0.id != id })
        }
    }
    public func clear() throws {
        try sealed.files.transaction {
            try sealed.files.remove("entries.sealed"); try sealed.secrets.delete(account: Self.keyAccount)
        }
    }
    private func load() throws -> [HistoryEntry] {
        try sealed.load([HistoryEntry].self, "entries.sealed", max: maximumBytes) ?? []
    }
    private func save(_ entries: [HistoryEntry]) throws {
        if entries.isEmpty { try sealed.files.remove("entries.sealed") }
        else { try sealed.save(entries, "entries.sealed", max: maximumBytes) }
    }
    private func prune(_ entries: [HistoryEntry], settings: HistorySettings) -> [HistoryEntry] {
        Array(entries.filter { $0.createdAt > now().addingTimeInterval(-settings.retention.seconds) && $0.createdAt <= now() }
            .sorted { $0.createdAt < $1.createdAt }.suffix(200))
    }
}
