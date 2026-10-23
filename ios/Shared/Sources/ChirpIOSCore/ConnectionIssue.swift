import ChirpCore
import Foundation

/// Why the Mac could not be reached, decided from error codes only: never from messages, hosts or URLs.
public enum ConnectionIssue: String, Sendable, CaseIterable, Equatable {
    /// This device has no network.
    case offline
    /// The tailnet name did not resolve: the Mac is off the tailnet or Tailscale is off here.
    case notFound
    /// Nothing answered: the Mac may be asleep, or chirp-server isn't running.
    case down
    case secure
    /// The Mac answered but refused this device's token (for example a revoked device pairing).
    case refused
    case other

    public static func classify(_ error: Error) -> ConnectionIssue {
        if let issue = (error as? ConnectionIssueError)?.issue { return issue }
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else { return .other }
        switch URLError.Code(rawValue: e.code) {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive: return .offline
        case .cannotFindHost, .dnsLookupFailed: return .notFound
        case .cannotConnectToHost, .timedOut, .networkConnectionLost: return .down
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired: return .secure
        case .userAuthenticationRequired: return .refused
        default: return .other
        }
    }

    /// `StreamSession` reports a short fixed reason when the socket fails; these are its known values.
    public static func classify(streamReason reason: String) -> ConnectionIssue {
        switch reason {
        case "Server unreachable", "Server did not answer in time": .down
        case "Server rejected the connection (check the token)": .refused
        default: .other
        }
    }

    /// The Mac is not answering at all, as opposed to answering with an error.
    public var isOffline: Bool { self == .offline || self == .notFound || self == .down }

    public var message: String {
        switch self {
        case .offline: "This device is offline. Connect to a network and try again."
        case .notFound: "Can't find your Mac on the tailnet. Is it online, with Tailscale on here?"
        case .down: "Your Mac may be asleep, or Chirp isn't running on it."
        case .secure: "Couldn't make a secure connection to your Mac."
        case .refused: "Your Mac refused this device. Pair again in Chirp."
        case .other: "Connection failed. Check Tailscale and your Mac."
        }
    }

    public var diagnostic: DiagnosticCode {
        switch self {
        case .offline: .offline
        case .notFound: .notFound
        case .down, .other: .unreachable
        case .secure: .secure
        case .refused: .auth
        }
    }
}

public struct ConnectionIssueError: Error, Equatable, Sendable {
    public let issue: ConnectionIssue
    public init(_ issue: ConnectionIssue) { self.issue = issue }
}

extension ServerConfig {
    /// Like `fetchHealth`, but keeps a 401 (the server's answer to a revoked device token) distinct from
    /// other failures, so the app can ask for a re-pair instead of blaming the network.
    public func checkHealth(session: URLSession) async throws -> Health {
        var request = authorized(URLRequest(url: healthURL))
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 401 { throw ConnectionIssueError(.refused) }
        guard status == 200, data.count <= 64 * 1024 else { throw ConnectionIssueError(.other) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(Health.self, from: data) } catch { throw ConnectionIssueError(.other) }
    }
}
