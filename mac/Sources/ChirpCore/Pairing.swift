import Foundation

/// A `chirp://pair?url=…&token=…` link, the same format `chirp-server pair` prints. It carries a bearer token, so it is a
/// secret: its description is redacted and it is never logged, put in a notification or written to disk.
public struct PairingLink: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let serverURL: URL
    private let token: String

    /// The same checks as `chirp-server pair`: an HTTP(S) base URL with a host and no credentials, and a token.
    public init(serverURL: URL, token: String) throws(PairingError) {
        guard ["http", "https"].contains(serverURL.scheme?.lowercased() ?? ""), !(serverURL.host ?? "").isEmpty,
              serverURL.user == nil, serverURL.password == nil else { throw .invalidURL }
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw .noToken }
        self.serverURL = serverURL
        self.token = t
    }

    /// What the QR code and Copy Pairing Link carry. Encoded like Python's `urlencode` (`quote_plus`), so it is
    /// byte-for-byte what `chirp-server pair --url <serverURL>` prints for the same token.
    public var uri: String {
        "chirp://pair?url=\(Self.formEncode(serverURL.absoluteString))&token=\(Self.formEncode(token))"
    }

    public var description: String { "PairingLink(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["serverURL": serverURL]) }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-~")
        allowed.insert(" ")
        return (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "").replacingOccurrences(of: " ", with: "+")
    }
}

public enum PairingError: Error, Equatable, Sendable {
    case invalidURL, noToken
}

/// The seam where a pairing link's token comes from. Today the shared token, as `chirp-server pair` reads it; per-device
/// tokens can replace it without touching the window.
public protocol PairingLinkMaker: Sendable {
    func link(serverURL: URL) async throws -> PairingLink
}

/// The shared bearer token in `~/.config/chirp/token`, the one `chirp-server pair` puts in its link today.
public struct SharedTokenPairing: PairingLinkMaker {
    public let tokenPath: String
    public init(tokenPath: String = ServerConfig.defaultTokenPath) { self.tokenPath = tokenPath }

    public func link(serverURL: URL) async throws -> PairingLink {
        guard let token = ServerConfig.readToken(path: tokenPath) else { throw PairingError.noToken }
        return try PairingLink(serverURL: serverURL, token: token)
    }
}
