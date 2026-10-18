#if DEBUG
import ChirpCore
import ChirpIOSCore
import Foundation

/// Synthetic-only in-memory dependencies. Not compiled into Release. No mic, Keychain or network access.
final class SyntheticHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let health = #"{"ok":true,"ready":true,"engine":"synthetic","debug_retention":false,"correction":"available","correction_leaves_machine":false}"#
        let profiles = #"{"profiles":[{"id":"default","name":"Default","description":"Synthetic test style","rewrites":false,"prompt":"Keep all words.","max_prompt_chars":4000}]}"#
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((url.path.hasSuffix("profiles") ? profiles : health).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SyntheticTransport: StreamTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let incoming: AsyncStream<URLSessionWebSocketTask.Message>
    private let continuation: AsyncStream<URLSessionWebSocketTask.Message>.Continuation
    private var iterator: AsyncStream<URLSessionWebSocketTask.Message>.Iterator
    private var sentValues: [URLSessionWebSocketTask.Message] = []
    let automatic: Bool
    init(automatic: Bool = false) {
        self.automatic = automatic
        let (input, output) = AsyncStream.makeStream(of: URLSessionWebSocketTask.Message.self)
        incoming = input; continuation = output; iterator = input.makeAsyncIterator()
    }
    var sent: [URLSessionWebSocketTask.Message] { lock.withLock { sentValues } }
    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock { sentValues.append(message) }
        guard automatic, case .string(let text) = message else { return }
        if text.contains(#""type":"start""#) {
            push(#"{"type":"ready","session":"synthetic","debug_retention":false}"#)
            push(#"{"type":"partial","seq":1,"text":"synthetic words","stable":"","words":[{"text":"synthetic","start":0,"end":0.2,"stable":false}]}"#)
        } else if text.contains(#""type":"stop""#) {
            push(#"{"type":"correcting","seq":2,"raw":"synthetic words","profile":"default"}"#)
            push(#"{"type":"final","text":"Synthetic words.","raw":"synthetic words","corrected":true}"#)
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        // StreamSession has exactly one receiver. Keep the iterator local across suspension for Swift 6.
        var current = lock.withLock { iterator }
        guard let next = await current.next() else { throw URLError(.cancelled) }
        lock.withLock { iterator = current }
        return next
    }
    func cancel(with code: URLSessionWebSocketTask.CloseCode) { continuation.finish() }
    func push(_ value: String) { continuation.yield(.string(value)) }
}

@MainActor
final class SyntheticAudio: SessionAudio {
    private(set) var armed = false
    private(set) var finishCount = 0
    private(set) var limits: [@Sendable () -> Void] = []
    private(set) var failures: [@Sendable () -> Void] = []
    private var stream: StreamSession?
    func arm(onInterruption: @escaping @Sendable () -> Void) throws { armed = true }
    func begin(stream: StreamSession, onFailure: @escaping @Sendable () -> Void, onLimit: @escaping @Sendable () -> Void) throws {
        self.stream = stream; limits.append(onLimit); failures.append(onFailure)
    }
    func ready() { stream?.sendAudio(Data(count: 1600)) }
    func finish() { finishCount += 1; stream?.sendAudio(Data(count: 640)) }
    func discard() { stream = nil }
    func disarm() { armed = false; stream = nil }
}

extension SessionCoordinator {
    static func synthetic() -> SessionCoordinator {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-synthetic-" + UUID().uuidString)
            let services = try AppServices(root: root, secrets: MemorySecretStore())
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SyntheticHTTP.self]
            return SessionCoordinator(services: services, audio: SyntheticAudio(), http: URLSession(configuration: config),
                makeStream: { _, options, _ in StreamSession(transport: SyntheticTransport(automatic: true), options: options) },
                requestPermission: { true }, permissionGranted: { true }, activityBegin: { _ in }, activityActive: { true },
                activityUpdate: { _, _ in }, activityEnd: {}, production: false)
        } catch { return SessionCoordinator(production: false) }
    }
}
#endif
