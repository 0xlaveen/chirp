import ChirpCore
import CryptoKit
import Foundation

/// Live Notes switches. Preferences only, never notes content. Fields missing from an older file keep their defaults.
public struct NotesPreferences: Codable, Sendable, Equatable {
    /// "Structure notes": nil follows the server (on when clean-up stays on the Mac).
    public var structure: Bool?
    /// The host the user allowed structuring to send text to, when clean-up leaves the Mac.
    public var structureConsentHost: String?
    public var autoReorganize = true
    /// Legacy preference, decoded only to preserve an explicit opt-out on upgrade.
    public var recoveryCopy = true
    public var keepNotes = true
    public var keepAudio = false
    public var retention: NotesRetention = .never
    public var libraryUpgradeNotice = false
    /// "Battery saver while locked": no screen updates while the app is in the background (recording and structuring
    /// go on; the Live Activity keeps its own timer).
    public var batterySaver = true
    /// "Label speakers": who said what, from the user's own server. Nil is "never chose", which is on (`speakerLabelsOn`);
    /// only the user's own Turn off stores `false`. The server fetches its speaker model itself when it is missing.
    /// Nothing about a voice is stored here or anywhere on the phone.
    public var labelSpeakers: Bool?
    /// Which default `labelSpeakers` was stored under. Before 2 the field was a plain `false` for everyone who had not
    /// switched labels on, so a stored `false` below 2 is "never chose" and is cleared once (`true` is kept).
    public var speakerLabelsDefault = NotesPreferences.speakerLabelsDefaultVersion
    public static let speakerLabelsDefaultVersion = 2
    public var speakerLabelsOn: Bool { labelSpeakers ?? true }
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        structure = try c.decodeIfPresent(Bool.self, forKey: .structure)
        structureConsentHost = try c.decodeIfPresent(String.self, forKey: .structureConsentHost)
        autoReorganize = try c.decodeIfPresent(Bool.self, forKey: .autoReorganize) ?? true
        recoveryCopy = try c.decodeIfPresent(Bool.self, forKey: .recoveryCopy) ?? true
        keepNotes = try c.decodeIfPresent(Bool.self, forKey: .keepNotes) ?? recoveryCopy
        keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? false
        retention = try c.decodeIfPresent(NotesRetention.self, forKey: .retention) ?? .never
        libraryUpgradeNotice = try c.decodeIfPresent(Bool.self, forKey: .libraryUpgradeNotice) ?? !recoveryCopy
        batterySaver = try c.decodeIfPresent(Bool.self, forKey: .batterySaver) ?? true
        let stored = try c.decodeIfPresent(Bool.self, forKey: .labelSpeakers)
        let version = try c.decodeIfPresent(Int.self, forKey: .speakerLabelsDefault) ?? 1
        labelSpeakers = version < Self.speakerLabelsDefaultVersion && stored == false ? nil : stored
        speakerLabelsDefault = Self.speakerLabelsDefaultVersion
    }

    /// Whether structuring runs against a server with this health. Unknown health is off (nothing says where the text
    /// would go); a destination off the Mac needs the user's consent for exactly that host.
    public func structureEnabled(health: Health?) -> Bool {
        guard let health, health.correctionAvailable else { return false }
        if health.correctionLeavesMachine == false { return structure ?? true }
        guard health.correctionLeavesMachine == true, let host = health.correctionHost, !host.isEmpty else { return false }
        return structure == true && structureConsentHost == host
    }
}

/// Local Notes library and legacy recovery journal, AES-GCM sealed with the same device-only Keychain key.
/// The library and optional AAC segments use a separate authentication context from legacy recovery records.
/// All folders are owner-only, backup-excluded and (on iOS) completely file-protected.
public final class NotesStore: Sendable {
    static let keyAccount = "notes-recovery-key"
    private let files: ProtectedFiles
    private let secrets: any SecretStore
    private let key: KeyBox
    public let recoveryDirectory: URL
    public let libraryStore: NotesLibraryStore

    public init(root: URL, secrets: any SecretStore, now: @escaping @Sendable () -> Date = { Date() }) throws {
        let folder = root.appendingPathComponent("notes", isDirectory: true)
        files = try ProtectedFiles(root: folder)
        recoveryDirectory = folder.appendingPathComponent("recovery", isDirectory: true)
        _ = try ProtectedFiles(root: recoveryDirectory)
        self.secrets = secrets
        let key = KeyBox(secrets: secrets, account: Self.keyAccount)
        self.key = key
        let libraryDirectory = folder.appendingPathComponent("library", isDirectory: true)
        _ = try ProtectedFiles(root: libraryDirectory)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: libraryDirectory.path)
        #endif
        libraryStore = NotesLibraryStore(directory: libraryDirectory, codec: Self.codec(key: key, context: "chirp.notes.library.v1"), now: now)
    }

    /// `Application Support/Chirp` in the app's own container (the keyboard never needs notes).
    public static func production(secrets: any SecretStore) throws -> NotesStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return try NotesStore(root: support.appendingPathComponent("Chirp", isDirectory: true), secrets: secrets)
    }

    public func loadPreferences() throws -> NotesPreferences {
        try files.transaction { try files.load(NotesPreferences.self, "preferences.json", max: 16_384) ?? NotesPreferences() }
    }
    public func save(_ preferences: NotesPreferences) throws {
        guard (preferences.structureConsentHost?.utf8.count ?? 0) <= 256 else { throw CoreError.oversized }
        try files.transaction { try files.save(preferences, "preferences.json", max: 16_384) }
    }

    /// The journal store: every record sealed before it reaches the disk. A file this key cannot open is skipped.
    public var journalStore: NotesJournalStore {
        NotesJournalStore(directory: recoveryDirectory, codec: Self.codec(key: key, context: "chirp.notes.v1"))
    }

    private static func codec(key: KeyBox, context: String) -> NotesJournalCodec {
        let context = Data(context.utf8)
        return NotesJournalCodec(seal: { plain in
            guard let sealed = try AES.GCM.seal(plain, using: key.get(create: true), authenticating: context).combined
            else { throw CoreError.storage }
            return sealed
        }, open: { sealed in
            try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key.get(create: false), authenticating: context)
        })
    }

    /// Each source is removed only after the sealed destination is durable. Invalid records are kept in quarantine;
    /// future schemas and files inaccessible while locked remain untouched for a later launch.
    public func migrateRecovery() async throws {
        let journal = journalStore
        for url in try FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            guard let stored = try? Data(contentsOf: url) else { continue }
            do {
                let data = try journal.codec!.open(stored)
                struct Header: Decodable { var schema: Int }
                let schema = try JSONDecoder().decode(Header.self, from: data).schema
                if ![1, 2].contains(schema) { continue }
                _ = try JSONDecoder().decode(NotesJournalRecord.self, from: data)
            } catch {
                let quarantine = recoveryDirectory.appendingPathComponent("quarantine", isDirectory: true)
                _ = try ProtectedFiles(root: quarantine)
                try FileManager.default.moveItem(at: url, to: quarantine.appendingPathComponent(url.lastPathComponent + "-" + UUID().uuidString))
            }
        }
        try await libraryStore.migrate(from: journal)
    }

    /// Removes only legacy journals; the library shares this key and must remain readable.
    public func deleteRecovery() throws {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: recoveryDirectory.path)) ?? [] {
            try? fm.removeItem(at: recoveryDirectory.appendingPathComponent(name))
        }
    }
}

/// The recovery key, read from the Keychain once and kept in memory for the process.
private final class KeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private let secrets: any SecretStore
    private let account: String
    private var cached: SymmetricKey?
    init(secrets: any SecretStore, account: String) { self.secrets = secrets; self.account = account }
    func get(create: Bool) throws -> SymmetricKey {
        try lock.withLock {
            if let cached { return cached }
            if let data = try secrets.read(account: account) {
                guard data.count == 32 else { throw CoreError.corrupt }
                cached = SymmetricKey(data: data)
            } else {
                guard create else { throw CoreError.unavailable }
                let key = SymmetricKey(size: .bits256)
                try secrets.write(key.withUnsafeBytes { Data($0) }, account: account)
                cached = key
            }
            return cached!
        }
    }
    func forget() { lock.withLock { cached = nil } }
}

/// A text editor edits what it last showed. When an AI change landed in between, the edit moves onto the current text
/// if the two changes are apart (the AI change wholly before or after it); otherwise it is dropped and the editor shows
/// the current text again.
public enum NotesEditRebase {
    public static func change(shown: String, edited: String, current: String) -> NotesTextChange? {
        guard let edit = NotesDocument.diff(shown, edited, kind: .user) else { return nil }
        guard let ai = NotesDocument.diff(shown, current, kind: .append) else { return edit }
        if ai.range.location > edit.range.upperBound { return edit }
        guard ai.range.upperBound < edit.range.location else { return nil }
        let shift = (ai.replacement as NSString).length - ai.range.length
        return NotesTextChange(range: NSRange(location: edit.range.location + shift, length: edit.range.length),
                               replacement: edit.replacement, kind: .user)
    }
}
