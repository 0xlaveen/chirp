import ChirpCore
import Foundation

// Learn from my edits on iPhone and iPad (#271 A2-5), with the Mac's `LearnedItem`s, `EditCorrections` and
// `start.learned` payload. iOS has no reliable identity for the app a keyboard types into, so only terms (the user's
// names and technical words, used in every app) are learned, never a per-app style. Nothing here is logged.

/// The learned items, sealed like the history (AES-GCM, a Keychain key of its own) in the app group, so the app
/// (Teach Chirp, Learned) and Chirp Keyboard (a fix right after a dictation) share them under one cross-process lock.
/// Disk is authoritative: nothing is cached, so neither process overwrites the other's change.
public final class IOSLearnedStore: Sendable {
    public static let keyAccount = "learned.aes.v1"
    static let fileName = "learned.sealed"
    static let maximumBytes = 1_048_576
    static let maxText = 300
    private let sealed: SealedStorage
    private let permitted: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    /// `permitted` is checked again under the lock before every write and payload.
    public init(root: URL, secrets: any SecretStore, permitted: @escaping @Sendable () -> Bool,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        sealed = SealedStorage(files: try ProtectedFiles(root: root.appendingPathComponent("learned", isDirectory: true)),
                               secrets: secrets, account: Self.keyAccount)
        self.permitted = permitted; self.now = now
    }

    /// The production gate: Learn from my edits on, dictation history on, and no private session.
    public convenience init(root: URL, secrets: any SecretStore) throws {
        let history = try HistoryStore(root: root, secrets: secrets)
        let preferences = try PreferenceStore(root: root)
        try self.init(root: root, secrets: secrets, permitted: {
            guard let prefs = try? preferences.load(), prefs.learning, !prefs.privacyMode else { return false }
            return (try? history.settings().enabled) == true
        })
    }

    /// Learning may happen now (Teach Chirp is offered and Chirp Keyboard watches its dictations).
    public var allowed: Bool { permitted() }

    /// Every item, the most recent first.
    public func all() throws -> [LearnedItem] {
        try sealed.files.transaction { try load() }.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// One edit, `inserted` → `edited`: its terms are counted, and used once seen `LearnedStore.threshold` times or
    /// at once when `explicit` (Teach Chirp). An item the user turned off stays off. Returns the items that became
    /// active just now; nothing is written while learning is not allowed.
    @discardableResult
    public func learn(inserted: String, edited: String, said: String?, explicit: Bool = false) throws -> [LearnedItem] {
        let corrections = Self.corrections(inserted: inserted, edited: edited)
        guard !corrections.isEmpty else { return [] }
        return try sealed.files.transaction {
            guard permitted() else { return [] }
            var items = try load()
            var activated: [LearnedItem] = []
            let date = now()
            for correction in corrections {
                if let i = items.firstIndex(where: { $0.correction == correction }) {
                    var item = items[i]
                    item.count = min(item.count + 1, 1_000_000); item.lastSeen = date
                    item.inserted = Self.bounded(inserted); item.edited = Self.bounded(edited); item.said = said.map(Self.bounded)
                    if item.state == .learning, item.count >= LearnedStore.threshold || explicit {
                        item.state = .active; activated.append(item)
                    }
                    items[i] = item
                } else {
                    let item = LearnedItem(correction: correction, bundleID: nil, appName: nil,
                                           state: explicit ? .active : .learning, count: 1, firstSeen: date, lastSeen: date,
                                           inserted: Self.bounded(inserted), edited: Self.bounded(edited), said: said.map(Self.bounded))
                    items.append(item)
                    if explicit { activated.append(item) }
                }
            }
            try save(Self.trim(items))
            return activated
        }
    }

    /// Approve (use it now), Undo (stop using it, and don't learn it again) or back to learning.
    public func set(_ id: UUID, state: LearnedItem.State) throws {
        try mutate { items in
            if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = state }
        }
    }

    public func delete(_ id: UUID) throws { try mutate { $0.removeAll { $0.id == id } } }

    public func clear() throws {
        try sealed.files.transaction {
            try sealed.files.remove(Self.fileName); try sealed.secrets.delete(account: Self.keyAccount)
        }
    }

    /// What a dictation sends with `start.learned`: every active term (no app, so no style). Empty while learning
    /// is not allowed.
    public func payload() throws -> LearnedPayload {
        try sealed.files.transaction {
            guard permitted() else { return LearnedPayload() }
            return LearnedStore.payload(try load().sorted { $0.lastSeen > $1.lastSeen }, for: nil)
        }
    }

    /// The terms in one edit. Style needs the app it was made in, which iOS cannot tell.
    static func corrections(inserted: String, edited: String) -> [LearnedCorrection] {
        EditCorrections.extract(inserted: inserted, edited: edited).filter { if case .term = $0 { true } else { false } }
    }

    static func bounded(_ text: String) -> String { String(text.prefix(maxText)) }

    /// At most `LearnedStore.maxItems`: the oldest still learning go first, then the oldest turned off.
    static func trim(_ items: [LearnedItem]) -> [LearnedItem] {
        var list = items
        for state in [LearnedItem.State.learning, .off, .active] where list.count > LearnedStore.maxItems {
            let victims = list.filter { $0.state == state }.sorted { $0.lastSeen < $1.lastSeen }.prefix(list.count - LearnedStore.maxItems)
            let ids = Set(victims.map(\.id))
            list.removeAll { ids.contains($0.id) }
        }
        return list
    }

    private func mutate(_ change: (inout [LearnedItem]) -> Void) throws {
        try sealed.files.transaction {
            var items = try load()
            change(&items)
            try save(items)
        }
    }

    /// A missing key means the file can never be read, and a damaged file never will be: both go. A Keychain that
    /// cannot be read now (locked) is not proof of either, so its error is thrown and the file kept.
    private func load() throws -> [LearnedItem] {
        guard try sealed.files.read(Self.fileName, max: Self.maximumBytes) != nil else { return [] }
        guard try sealed.secrets.read(account: Self.keyAccount) != nil else { try sealed.files.remove(Self.fileName); return [] }
        do { return try sealed.load([LearnedItem].self, Self.fileName, max: Self.maximumBytes) ?? [] }
        catch { try sealed.files.remove(Self.fileName); return [] }
    }

    private func save(_ items: [LearnedItem]) throws {
        if items.isEmpty { try sealed.files.remove(Self.fileName) }
        else { try sealed.save(items, Self.fileName, max: Self.maximumBytes) }
    }
}

/// Chirp Keyboard's view of one dictation it inserted: the field as the final landed, then as the user left it.
/// The learned edit is only the inserted span, and only when everything around it is unchanged (`EditRegion`), so a
/// host that shows a shifted or partial window, a moved caret outside the span, or other typing teaches nothing.
/// Field text stays in memory for the window only.
public struct LearningWatch: Sendable {
    public static let window: TimeInterval = 60
    public let documentID: UUID?
    public let inserted: String
    public let said: String
    public let until: Date
    private let field: String
    private let range: NSRange
    private var latest: String

    /// `before`/`after`: the host's text around the caret right after the final landed, ending with `inserted`.
    public init?(documentID: UUID?, before: String, after: String, inserted: String, said: String, now: Date) {
        guard before.hasSuffix(inserted), !inserted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (before + after).utf16.count <= 100_000 else { return nil }
        self.documentID = documentID; self.inserted = inserted; self.said = String(said.prefix(IOSLearnedStore.maxText))
        until = now.addingTimeInterval(Self.window)
        field = before + after
        let start = (before as NSString).length - (inserted as NSString).length
        range = NSRange(location: start, length: (inserted as NSString).length)
        latest = field
    }

    /// One look at the same field; another document is ignored (`finish` decides).
    public mutating func observe(documentID: UUID?, before: String?, after: String?) {
        guard documentID == self.documentID, let before, let after, (before + after).utf16.count <= 100_000 else { return }
        latest = before + after
    }

    /// The inserted span as the user left it, nil when it is unchanged or the change cannot be pinned to it.
    public var edited: String? {
        guard let edited = EditRegion.edited(before: field, after: latest, range: range), edited != inserted,
              !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return edited
    }
}
