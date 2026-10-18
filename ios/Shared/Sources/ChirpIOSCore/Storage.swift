import Foundation
import CryptoKit
import Security
import Darwin

/// Errors contain fixed local codes only, never data received from a server or Keychain.
public enum CoreError: String, Error, Sendable {
    case invalidPairing, invalidURL, invalidToken, unavailable, storage, oversized, corrupt, unauthorized
    case expired, replay, staleGeneration, foreignUtterance, queueFull, invalidState
}

public protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

/// Injectable test store. Production callers must use KeychainSecretStore.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public init() {}
    public func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    public func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    public func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

public struct KeychainSecretStore: SecretStore {
    public let accessGroup: String?
    public init(accessGroup: String? = nil) { self.accessGroup = accessGroup }
    private func query(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.chirp.ios.shared", kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }
    public func read(account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CoreError.unavailable }
        return data
    }
    public func write(_ data: Data, account: String) throws {
        let q = query(account)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = q
            values.forEach { item[$0] = $1 }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CoreError.unavailable }
        } else if status != errSecSuccess { throw CoreError.unavailable }
    }
    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CoreError.unavailable }
    }
}

public struct SharedConfiguration: Sendable {
    public let appGroupID: String
    public let keychainAccessGroup: String?
    public init(appGroupID: String = "group.dev.chirp.ios", keychainAccessGroup: String? = nil) {
        self.appGroupID = appGroupID; self.keychainAccessGroup = keychainAccessGroup
    }
    public init(bundle: Bundle) {
        appGroupID = bundle.object(forInfoDictionaryKey: "ChirpAppGroup") as? String ?? "group.dev.chirp.ios"
        keychainAccessGroup = bundle.object(forInfoDictionaryKey: "ChirpKeychainAccessGroup") as? String
    }
    public func containerURL() throws -> URL {
        guard !appGroupID.isEmpty, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else { throw CoreError.unavailable }
        return url.appendingPathComponent("Chirp", isDirectory: true)
    }
}

/// All read-modify-write operations lock a stable inode, across instances AND processes. Never unlink the lock.
/// Directory/storage URLs must be dedicated to Chirp and on a local App Group volume.
final class ProtectedFiles: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try Self.protect(root)
    }
    static func protect(_ url: URL) throws {
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw CoreError.storage }
            defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw CoreError.storage }
            defer { flock(fd, LOCK_UN) }
            return try body()
        }
    }
    func read(_ name: String, max: Int = 1_048_576) throws -> Data? {
        let path = root.appendingPathComponent(name).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw CoreError.storage
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= max else { throw CoreError.oversized }
        var data = Data(count: Int(info.st_size))
        let expected = data.count
        let count = data.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var done = 0
            while done < expected {
                let n = Darwin.read(fd, base.advanced(by: done), expected - done)
                if n <= 0 { return -1 }
                done += n
            }
            return done
        }
        guard count == expected else { throw CoreError.storage }
        return data
    }
    func write(_ data: Data, _ name: String, max: Int = 1_048_576) throws {
        guard data.count <= max else { throw CoreError.oversized }
        let temporary = root.appendingPathComponent(".tmp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Apply protection/exclusion before bytes exist. Only ciphertext or allowlisted metadata enters this layer.
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CoreError.storage
        }
        try Self.protect(temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw CoreError.storage }
        guard rename(temporary.path, root.appendingPathComponent(name).path) == 0 else { throw CoreError.storage }
    }
    func remove(_ name: String) throws {
        let path = root.appendingPathComponent(name).path
        guard unlink(path) == 0 || errno == ENOENT else { throw CoreError.storage }
    }
    func load<T: Decodable>(_ type: T.Type, _ name: String, max: Int = 1_048_576) throws -> T? {
        guard let data = try read(name, max: max) else { return nil }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw CoreError.corrupt }
    }
    func save<T: Encodable>(_ value: T, _ name: String, max: Int = 1_048_576) throws {
        try write(JSONEncoder().encode(value), name, max: max)
    }
}

struct SealedStorage {
    let files: ProtectedFiles
    let secrets: any SecretStore
    let account: String
    func key(create: Bool) throws -> SymmetricKey {
        if let data = try secrets.read(account: account) {
            guard data.count == 32 else { throw CoreError.corrupt }
            return SymmetricKey(data: data)
        }
        guard create else { throw CoreError.unavailable }
        let key = SymmetricKey(size: .bits256)
        try secrets.write(key.withUnsafeBytes { Data($0) }, account: account)
        return key
    }
    func load<T: Decodable>(_ type: T.Type, _ name: String, max: Int = 1_048_576) throws -> T? {
        guard let data = try files.read(name, max: max) else { return nil }
        do {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(create: false),
                                         authenticating: Data(("chirp.v1:" + name).utf8))
            return try JSONDecoder().decode(type, from: plain)
        } catch { throw CoreError.corrupt }
    }
    func save<T: Encodable>(_ value: T, _ name: String, max: Int = 1_048_576) throws {
        let plain = try JSONEncoder().encode(value)
        guard plain.count + 28 <= max else { throw CoreError.oversized }
        let sealed = try AES.GCM.seal(plain, using: key(create: true), authenticating: Data(("chirp.v1:" + name).utf8))
        guard let combined = sealed.combined else { throw CoreError.storage }
        try files.write(combined, name, max: max)
    }
}
