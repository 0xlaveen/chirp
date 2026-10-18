import Foundation
import Testing
import ChirpCore
@testable import ChirpIOSCore

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

struct PairingTests {
    @Test func validPairingPreservesBasePathAndKeepsTokenOutOfURLs() throws {
        let c = try PairingLink.parse("chirp://pair?url=https%3A%2F%2Fmac.tail123.ts.net%2Fchirp&token=synthetic")
        #expect(c.config.healthURL.absoluteString == "https://mac.tail123.ts.net/chirp/v1/health")
        #expect(c.config.streamURL.absoluteString == "wss://mac.tail123.ts.net/chirp/v1/stream")
        #expect(!c.description.contains("synthetic"))
        #expect(c.config.authorized(URLRequest(url: c.config.healthURL)).value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
    }
    @Test(arguments: [
        "chirp://pair?url=https://mac.tail.ts.net&token=a&token=b",
        "chirp://pair?url=https://mac.tail.ts.net&token=a&secret=b",
        "chirp://pair/?url=https://mac.tail.ts.net&token=a",
        "chirp://pair?url=https://mac.tail.ts.net&token=",
        "chirp://pair?url=https://mac.tail.ts.net&token=a%0D%0Ab",
        "chirp://other?url=https://mac.tail.ts.net&token=a",
        "chirp://user@pair?url=https://mac.tail.ts.net&token=a",
        "chirp://pair?url=https://mac.tail.ts.net&token=a#bad"
    ]) func invalidPairing(_ value: String) { #expect(throws: (any Error).self) { try PairingLink.parse(value) } }
    @Test(arguments: ["http://mac.tail.ts.net", "https://example.com", "https://ts.net", "https://evilts.net",
        "https://mac.ts.net.evil.com", "https://u:p@mac.ts.net", "https://mac.ts.net?q=x", "https://mac.ts.net#x",
        "https://mac.ts.net/../x", "https://mac.ts.net/%2e%2e", "https://mac..ts.net", "https://-mac.ts.net",
        "https://mac.ts.net./chirp", "https://mac.ts.net:0", "https://mac.ts.net\\@evil.com"])
    func invalidBase(_ value: String) { #expect(throws: (any Error).self) { try PairingLink.validateBaseURL(value) } }
    @Test func authenticatedHealthRequiredAndSecretsStayInKeychain() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecretStore(); let store = try PairingStore(root: root, secrets: secrets)
        let credentials = try PairingCredentials(baseURL: URL(string: "https://mac.tail.ts.net/chirp")!, token: "synthetic-token-sentinel")
        await #expect(throws: CoreError.unauthorized) { try await store.verifyAndSave(credentials) { _ in Health() } }
        #expect(try store.load() == nil)
        try await store.verifyAndSave(credentials) { _ in Health(engine: "fake", ready: true) }
        #expect(try store.load() == credentials.config)
        for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("pairing"), includingPropertiesForKeys: nil) {
            #expect(!(try Data(contentsOf: file)).contains(Data("synthetic-token-sentinel".utf8)))
        }
        try store.clear(); #expect(try store.load() == nil)
    }
    @Test func clearFencesLateHealth() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PairingStore(root: root, secrets: MemorySecretStore())
        let credentials = try PairingCredentials(baseURL: URL(string: "https://mac.ts.net")!, token: "fake")
        await #expect(throws: CoreError.staleGeneration) {
            try await store.verifyAndSave(credentials) { _ in try store.clear(); return Health(engine: "fake", ready: true) }
        }
        #expect(try store.load() == nil)
    }
    @Test func ephemeralNetworkPolicyRejectsAllRedirects() throws {
        let session = SafeHTTPSession.make(); defer { session.invalidateAndCancel() }
        #expect(session.configuration.urlCache == nil)
        #expect(session.configuration.httpCookieStorage == nil)
        #expect(session.configuration.urlCredentialStorage == nil)
        #expect(!SafeHTTPSession.allowsRedirect(from: URL(string: "https://a.ts.net")!, to: URL(string: "https://b.ts.net")!))
    }
}

struct HistoryTests {
    @Test func defaultOffCiphertextAndDisableDeleteKey() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecretStore(); let history = try HistoryStore(root: root, secrets: secrets)
        #expect(!(try history.settings().enabled)); #expect(try history.record(text: "ignored") == nil)
        #expect(try secrets.read(account: HistoryStore.keyAccount) == nil)
        try history.setEnabled(true)
        try history.record(text: "transcript-sentinel", raw: "raw-sentinel", corrected: true)
        let file = root.appendingPathComponent("history/entries.sealed")
        let bytes = try Data(contentsOf: file)
        #expect(!bytes.contains(Data("transcript-sentinel".utf8))); #expect(!bytes.contains(Data("raw-sentinel".utf8)))
        #expect(try history.entries().first?.raw == "raw-sentinel")
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try history.setEnabled(false)
        #expect(!FileManager.default.fileExists(atPath: file.path)); #expect(try secrets.read(account: HistoryStore.keyAccount) == nil)
        #expect(try history.record(text: "racing completion") == nil)
    }
    @Test func capRetentionSearchAndDeletion() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(); let history = try HistoryStore(root: root, secrets: MemorySecretStore(), now: clock.now)
        try history.setEnabled(true)
        for n in 0..<205 { try history.record(text: "entry \(n)"); clock.advance(1) }
        #expect(try history.entries().count == 200)
        #expect(try history.entries().first?.text == "entry 204")
        let id = try #require(history.entries().first?.id); try history.delete(id: id)
        #expect(try history.entries().count == 199)
        try history.setRetention(.day); clock.advance(86_401); #expect(try history.entries().isEmpty)
        #expect(try history.record(text: " \n") == nil)
        try history.record(text: "new"); try history.clear(); #expect(try history.entries().isEmpty)
    }
    @Test func tamperAndMissingKeyFailClosed() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecretStore(); let history = try HistoryStore(root: root, secrets: secrets)
        try history.setEnabled(true); try history.record(text: "secret")
        let file = root.appendingPathComponent("history/entries.sealed")
        var data = try Data(contentsOf: file); data[data.count - 1] ^= 1; try data.write(to: file)
        #expect(throws: CoreError.corrupt) { try history.entries() }
        try history.clear(); try history.record(text: "secret")
        try secrets.delete(account: HistoryStore.keyAccount)
        #expect(throws: CoreError.corrupt) { try history.entries() }
        try history.setEnabled(false); #expect(try history.entries().isEmpty)
    }
    @Test func concurrentDisableAndWritersCannotResurrectData() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecretStore()
        let first = try HistoryStore(root: root, secrets: secrets), second = try HistoryStore(root: root, secrets: secrets)
        try first.setEnabled(true)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { _ = try? second.record(text: "racing") } }
            group.addTask { try? first.setEnabled(false) }
        }
        #expect(try first.entries().isEmpty)
        #expect(try secrets.read(account: HistoryStore.keyAccount) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("history/entries.sealed").path))
    }
}

struct BridgeTests {
    @Test func encryptedConsumeReplayOrderingAndOwnership() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), secrets = MemorySecretStore(), generation = UUID(), utterance = UUID()
        let app = try SharedBridge(root: root, secrets: secrets, role: .app, now: clock.now)
        let keyboard = try SharedBridge(root: root, secrets: secrets, role: .keyboard, now: clock.now)
        try app.publish(BridgeState(generation: generation, phase: .armed, leaseUntil: clock.now() + 8))
        let start = BridgeCommand(generation: generation, utteranceID: utterance, action: .start, createdAt: clock.now(), expiresAt: clock.now() + 10)
        try keyboard.send(start); #expect(try app.takeCommands(generation: generation) == [start])
        #expect(throws: CoreError.replay) { try keyboard.send(start) }
        try app.publish(BridgeState(generation: generation, phase: .listening, utteranceID: utterance, leaseUntil: clock.now() + 8))
        let partial = BridgeResult(generation: generation, utteranceID: utterance, kind: .partial, text: "sentinel-transcript", sequence: 1, createdAt: clock.now(), expiresAt: clock.now() + 10)
        try app.publish(partial)
        let data = try Data(contentsOf: root.appendingPathComponent("bridge/mailbox.sealed"))
        #expect(!data.contains(Data("sentinel-transcript".utf8)))
        #expect(try keyboard.takeResults(generation: generation, utteranceID: utterance) == [partial])
        #expect(try keyboard.takeResults(generation: generation, utteranceID: utterance).isEmpty)
        #expect(throws: CoreError.replay) { try app.publish(partial) }
        #expect(throws: CoreError.foreignUtterance) { try keyboard.takeResults(generation: generation, utteranceID: UUID()) }
        #expect(throws: CoreError.unauthorized) { try keyboard.publish(partial) }
        let final = BridgeResult(generation: generation, utteranceID: utterance, kind: .final, text: "final", sequence: 2, createdAt: clock.now(), expiresAt: clock.now() + 10)
        try app.publish(final)
        var repeated = final; repeated.id = UUID(); repeated.sequence = 3
        #expect(throws: CoreError.invalidState) { try app.publish(repeated) }
        var raw = repeated; raw.kind = .raw; raw.text = "raw"; try app.publish(raw)
        #expect(try keyboard.takeResults(generation: generation, utteranceID: utterance).map(\.kind) == [.final, .raw])
        try app.endSession(); #expect(try keyboard.state() == nil)
        #expect(throws: CoreError.staleGeneration) { try app.publish(BridgeState(generation: generation, phase: .armed, leaseUntil: clock.now() + 8)) }
    }
    @Test func expiryLeaseAndGenerationFence() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), secrets = MemorySecretStore(), generation = UUID(), utterance = UUID()
        let app = try SharedBridge(root: root, secrets: secrets, role: .app, now: clock.now)
        let keyboard = try SharedBridge(root: root, secrets: secrets, role: .keyboard, now: clock.now)
        try app.publish(BridgeState(generation: generation, phase: .listening, utteranceID: utterance, leaseUntil: clock.now() + 8))
        try app.publish(BridgeResult(generation: generation, utteranceID: utterance, kind: .partial, text: "expires", createdAt: clock.now(), expiresAt: clock.now() + 2))
        clock.advance(3); #expect(try keyboard.takeResults(generation: generation, utteranceID: utterance).isEmpty)
        clock.advance(6); #expect(try keyboard.state() == nil)
        #expect(throws: CoreError.staleGeneration) { try app.publish(BridgeState(generation: generation, phase: .armed, leaseUntil: clock.now() + 8)) }
        let next = UUID(); try app.publish(BridgeState(generation: next, phase: .armed, leaseUntil: clock.now() + 8))
        #expect(throws: CoreError.staleGeneration) { try keyboard.send(BridgeCommand(generation: generation, action: .end, createdAt: clock.now(), expiresAt: clock.now() + 5)) }
        #expect(try keyboard.state()?.generation == next)
    }
    @Test func queueBoundAndConcurrentWriters() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), secrets = MemorySecretStore(), generation = UUID()
        let app = try SharedBridge(root: root, secrets: secrets, role: .app, now: clock.now)
        try app.publish(BridgeState(generation: generation, phase: .armed, leaseUntil: clock.now() + 15))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    let writer = try SharedBridge(root: root, secrets: secrets, role: .keyboard, now: clock.now)
                    try writer.send(BridgeCommand(generation: generation, action: .privacy(true), createdAt: clock.now(), expiresAt: clock.now() + 10))
                }
            }
            try await group.waitForAll()
        }
        let writer = try SharedBridge(root: root, secrets: secrets, role: .keyboard, now: clock.now)
        #expect(throws: CoreError.queueFull) { try writer.send(BridgeCommand(generation: generation, action: .end, createdAt: clock.now(), expiresAt: clock.now() + 10)) }
        #expect(try app.takeCommands(generation: generation).count == 64)
    }
    @Test func tamperOversizeTTLAndRoleFailClosed() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), secrets = MemorySecretStore(), generation = UUID(), utterance = UUID()
        let app = try SharedBridge(root: root, secrets: secrets, role: .app, now: clock.now)
        #expect(throws: CoreError.invalidState) { try app.publish(BridgeState(generation: generation, phase: .armed, leaseUntil: clock.now() + 16)) }
        try app.publish(BridgeState(generation: generation, phase: .listening, utteranceID: utterance, leaseUntil: clock.now() + 8))
        #expect(throws: CoreError.oversized) { try app.publish(BridgeResult(generation: generation, utteranceID: utterance, kind: .final, text: String(repeating: "a", count: 65_537), createdAt: clock.now(), expiresAt: clock.now() + 10)) }
        #expect(throws: CoreError.expired) { try app.publish(BridgeResult(generation: generation, utteranceID: utterance, kind: .final, text: "a", createdAt: clock.now(), expiresAt: clock.now() + 121)) }
        let file = root.appendingPathComponent("bridge/mailbox.sealed")
        var data = try Data(contentsOf: file); data[data.count - 1] ^= 1; try data.write(to: file)
        #expect(throws: CoreError.corrupt) { try app.state() }
    }
}

struct PreferenceAndDiagnosticTests {
    @Test func defaultsConsentAndPersistence() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PreferenceStore(root: root); var preferences = try store.load()
        #expect(!preferences.correction); #expect(preferences.sessionDuration == .fiveMinutes)
        preferences.correction = true
        let external = Health(correction: "available", correctionLeavesMachine: true, correctionHost: "llm.example")
        #expect(!preferences.permitsCorrection(health: external))
        preferences.consentHost = "llm.example"; #expect(preferences.permitsCorrection(health: external))
        #expect(!preferences.permitsCorrection(health: Health(correction: "available", correctionLeavesMachine: true, correctionHost: "changed.example")))
        #expect(!preferences.permitsCorrection(health: Health(correction: "available")))
        try store.save(preferences); #expect(try store.load() == preferences)
    }
    @Test func diagnosticsCanOnlyExportAllowlistedContent() throws {
        #expect(DiagnosticCode.server("secret server exception transcript") == .unknown)
        let bytes = try DiagnosticExport.data(events: [DiagnosticEvent(phase: .failed, code: .unknown, durationMilliseconds: -1)])
        let string = String(decoding: bytes, as: UTF8.self)
        #expect(!string.contains("secret")); #expect(string.contains("failed"))
        #expect(!string.contains("token")); #expect(!string.contains("url"))
    }
}
