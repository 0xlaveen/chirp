import ChirpCore
import Foundation
import Testing
@testable import ChirpIOSCore

/// Answers every request with a fixed status and body; no network.
private final class FixedHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Connection issues", .serialized)
struct ConnectionIssueTests {
    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, ConnectionIssue.offline), (.dataNotAllowed, .offline),
        (.cannotFindHost, .notFound), (.dnsLookupFailed, .notFound),
        (.cannotConnectToHost, .down), (.timedOut, .down), (.networkConnectionLost, .down),
        (.secureConnectionFailed, .secure), (.serverCertificateUntrusted, .secure),
        (.badServerResponse, .other), (.cancelled, .other),
    ])
    func classifiesByCodeOnly(_ code: URLError.Code, _ expected: ConnectionIssue) {
        #expect(ConnectionIssue.classify(URLError(code)) == expected)
    }

    @Test func offlineKindsAreTheOnesWhereNothingAnswers() {
        #expect(ConnectionIssue.allCases.filter(\.isOffline) == [.offline, .notFound, .down])
        #expect(ConnectionIssue.refused.diagnostic == .auth && ConnectionIssue.down.diagnostic == .unreachable)
        for issue in ConnectionIssue.allCases { #expect(!issue.message.isEmpty && issue.message.count <= 80) }
    }

    @Test func streamReasonsMapToIssues() {
        #expect(ConnectionIssue.classify(streamReason: "Server unreachable") == .down)
        #expect(ConnectionIssue.classify(streamReason: "Server did not answer in time") == .down)
        #expect(ConnectionIssue.classify(streamReason: "Server rejected the connection (check the token)") == .refused)
        #expect(ConnectionIssue.classify(streamReason: "Connection lost") == .other)
    }

    @Test func checkHealthKeepsARevokedTokenDistinct() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixedHTTP.self]
        let session = URLSession(configuration: configuration)
        let config = ServerConfig(baseURL: URL(string: "https://mac.tail.ts.net/chirp")!, token: "synthetic")
        FixedHTTP.status = 401; FixedHTTP.body = Data(#"{"detail":"auth"}"#.utf8)
        await #expect(throws: ConnectionIssueError(.refused)) { try await config.checkHealth(session: session) }
        FixedHTTP.status = 503
        await #expect(throws: ConnectionIssueError(.other)) { try await config.checkHealth(session: session) }
        FixedHTTP.status = 200; FixedHTTP.body = Data(#"{"ok":true,"ready":true,"engine":"synthetic"}"#.utf8)
        let health = try await config.checkHealth(session: session)
        #expect(health.engine == "synthetic" && health.ready == true)
    }

    @Test func checkedHealthCarriesThisDevicesPairingName() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixedHTTP.self]
        let session = URLSession(configuration: configuration)
        let config = ServerConfig(baseURL: URL(string: "https://mac.tail.ts.net/chirp")!, token: "synthetic")
        FixedHTTP.status = 200
        FixedHTTP.body = Data(#"{"ok":true,"ready":true,"engine":"synthetic","device":"Akshay's iPad"}"#.utf8)
        #expect(try await config.checkedHealth(session: session).device == "Akshay's iPad")
        FixedHTTP.body = Data(#"{"ok":true,"ready":true,"engine":"synthetic"}"#.utf8)
        #expect(try await config.checkedHealth(session: session).device == nil, "The shared token has no name")
        FixedHTTP.body = Data(#"{"ok":true,"ready":true,"engine":"synthetic","device":"bad\nname"}"#.utf8)
        #expect(try await config.checkedHealth(session: session).device == nil)
    }

    @Test func bridgeResultsWithoutTheKeptFlagStillDecode() throws {
        let result = BridgeResult(generation: UUID(), utteranceID: UUID(), kind: .final, text: "x", expiresAt: Date())
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
        #expect(json["kept"] == nil)
        json.removeValue(forKey: "kept")
        let decoded = try JSONDecoder().decode(BridgeResult.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.kept == nil)
        var kept = result; kept.kept = true
        #expect(try JSONDecoder().decode(BridgeResult.self, from: JSONEncoder().encode(kept)).kept == true)
    }

    @Test func preferencesSavedBeforeSpokenCommandsStillLoad() throws {
        let old = #"{"correction":false,"styleID":"default","prompts":{},"sessionDuration":"fiveMinutes","privacyMode":false}"#
        let decoded = try JSONDecoder().decode(IOSPreferences.self, from: Data(old.utf8))
        #expect(decoded.spokenCommands == nil)
    }
}
