import Foundation

/// Where the server is and how to authenticate. The token lives in `~/.config/chirp/token`
/// (written by `chirp-server`); nothing else is persisted by the client.
public struct ServerConfig: Sendable, Equatable {
    public static let defaultURL = URL(string: "http://127.0.0.1:7821")!
    public static var defaultTokenPath: String { NSString(string: "~/.config/chirp/token").expandingTildeInPath }

    public var baseURL: URL
    public var token: String?

    public init(baseURL: URL = defaultURL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
    }

    public static func readToken(path: String = defaultTokenPath) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public static func load(urlString: String?, tokenPath: String = defaultTokenPath) -> ServerConfig {
        let url = urlString.flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) } ?? defaultURL
        return ServerConfig(baseURL: url, token: readToken(path: tokenPath))
    }

    /// `ws(s)://…/v1/stream`, keeping any base path such as `/chirp`.
    public var streamURL: URL {
        var c = URLComponents(url: baseURL.appendingPathComponent("v1/stream"), resolvingAgainstBaseURL: false)!
        c.scheme = (baseURL.scheme == "https" || baseURL.scheme == "wss") ? "wss" : "ws"
        return c.url!
    }

    public var healthURL: URL { baseURL.appendingPathComponent("v1/health") }

    /// `POST …/v1/notes/structure`, keeping any base path such as `/chirp`.
    public var notesStructureURL: URL { baseURL.appendingPathComponent("v1/notes/structure") }

    /// `POST …/v1/notes/reorganize`, keeping any base path such as `/chirp`.
    public var notesReorganizeURL: URL { baseURL.appendingPathComponent("v1/notes/reorganize") }

    public func authorized(_ request: URLRequest) -> URLRequest {
        var r = request
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    public var host: String { baseURL.host ?? baseURL.absoluteString }
    public var isLoopback: Bool { ["127.0.0.1", "localhost", "::1"].contains(baseURL.host ?? "") }

    public func fetchHealth(session: URLSession = .shared) async throws -> Health {
        var req = authorized(URLRequest(url: healthURL))
        req.timeoutInterval = 3
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Health.self, from: data)
    }

    /// One structuring pass. `timeout` is the server's structure timeout plus a margin; a client timeout throws the
    /// `URLError` and the caller treats it as `error: "timeout"`. Non-200 answers throw `NotesStructureError`.
    public func structureNotes(_ r: NotesStructureRequest, session: URLSession = .shared,
                               timeout: TimeInterval = 35) async throws -> NotesStructureResponse {
        try await postNotes(r, to: notesStructureURL, session: session, timeout: timeout)
    }

    /// One reorganize pass, with the same error mapping as `structureNotes` (a 404 means only reorganize is missing).
    public func reorganizeNotes(_ r: NotesReorganizeRequest, session: URLSession = .shared,
                                timeout: TimeInterval = 50) async throws -> NotesReorganizeResponse {
        try await postNotes(r, to: notesReorganizeURL, session: session, timeout: timeout)
    }

    private func postNotes<Request: Encodable, Response: Decodable>(_ r: Request, to url: URL, session: URLSession,
                                                                    timeout: TimeInterval) async throws -> Response {
        var req = authorized(URLRequest(url: url))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(r)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw NotesStructureError.from(status: status) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }
}
