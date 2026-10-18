import Foundation
import ChirpCore

public struct PairingCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let baseURL: URL
    public let token: String
    public var config: ServerConfig { ServerConfig(baseURL: baseURL, token: token) }
    public var description: String { "PairingCredentials(<redacted>)" }
    public var debugDescription: String { description }
    public init(baseURL: URL, token: String) throws {
        self.baseURL = try PairingLink.validateBaseURL(baseURL.absoluteString)
        guard PairingLink.validToken(token) else { throw CoreError.invalidToken }
        self.token = token
    }
}

public enum PairingLink {
    public static func parse(_ link: String) throws -> PairingCredentials {
        guard link.utf8.count <= 16_384,
              let c = URLComponents(string: link), c.scheme == "chirp", c.host == "pair",
              c.user == nil, c.password == nil, c.port == nil, c.path.isEmpty, c.fragment == nil,
              let items = c.queryItems, items.count == 2,
              Set(items.map(\.name)) == Set(["url", "token"]),
              let url = items.first(where: { $0.name == "url" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value else { throw CoreError.invalidPairing }
        return try PairingCredentials(baseURL: validateBaseURL(url), token: token)
    }
    static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 4096 && token.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
    }
    public static func validateBaseURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 4096, !value.contains("\\"),
              let c = URLComponents(string: value), c.scheme == "https",
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port == nil || (1...65535).contains(c.port!),
              let host = c.host, host == host.lowercased(), host.utf8.count <= 253,
              host.hasSuffix(".ts.net"), !host.contains("%"),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }),
              c.percentEncodedPath.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) ||
                  [UInt8(47), 45, 95, 46, 126].contains(byte)
              }),
              !c.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let url = c.url else { throw CoreError.invalidURL }
        return url
    }
}

/// No persistent cache, cookies, credentials or redirects. TLS validation remains the system default.
/// Rejecting ALL redirects also covers WebSocket redirects and scheme/port/path credential surprises.
public enum SafeHTTPSession {
    public static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 20
        return URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
    }
    public static func allowsRedirect(from: URL, to: URL) -> Bool { false }
}
private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Pairing is saved only after authenticated health. A clear/re-pair during verification fences out its late response.
public final class PairingStore: Sendable {
    private struct Stored: Codable { let baseURL: URL; let token: String }
    private let files: ProtectedFiles
    private let secrets: any SecretStore
    private let account = "pairing.v1"
    public init(root: URL, secrets: any SecretStore) throws {
        files = try ProtectedFiles(root: root.appendingPathComponent("pairing", isDirectory: true)); self.secrets = secrets
    }
    private func generation() throws -> UUID {
        if let id = try files.load(UUID.self, "generation.json") { return id }
        let id = UUID(); try files.save(id, "generation.json"); return id
    }
    public func load() throws -> ServerConfig? {
        try files.transaction {
            guard let data = try secrets.read(account: account) else { return nil }
            guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { throw CoreError.corrupt }
            return try PairingCredentials(baseURL: stored.baseURL, token: stored.token).config
        }
    }
    @discardableResult
    public func verifyAndSave(_ credentials: PairingCredentials, session: URLSession) async throws -> Health {
        try await verifyAndSave(credentials) { config in try await config.fetchHealth(session: session) }
    }
    @discardableResult
    public func verifyAndSave(_ credentials: PairingCredentials,
                              health: @Sendable (ServerConfig) async throws -> Health) async throws -> Health {
        let ticket = try files.transaction { try generation() }
        let result: Health
        do { result = try await health(credentials.config) } catch { throw CoreError.unavailable }
        // Unauthenticated health is only {ok:true}; never accept it as proof of bearer validation.
        guard result.ok, result.engine != nil, result.ready != nil else { throw CoreError.unauthorized }
        try files.transaction {
            guard try generation() == ticket else { throw CoreError.staleGeneration }
            try secrets.write(JSONEncoder().encode(Stored(baseURL: credentials.baseURL, token: credentials.token)), account: account)
            try files.save(UUID(), "generation.json")
        }
        return result
    }
    public func clear() throws {
        try files.transaction {
            try files.save(UUID(), "generation.json")
            try secrets.delete(account: account)
        }
    }
}
