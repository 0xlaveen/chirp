#if DEBUG
import ChirpCore
import ChirpIOSCore
import Foundation
import SwiftUI
import UIKit

/// Synthetic transport/audio. Not compiled into Release. No microphone or network access.
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
    static func synthetic(sharedKeyboard: Bool = false) -> SessionCoordinator {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-synthetic-" + UUID().uuidString)
            let services = try sharedKeyboard ? AppServices.production() : AppServices(root: root, secrets: MemorySecretStore())
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SyntheticHTTP.self]
            return SessionCoordinator(services: services, audio: SyntheticAudio(), http: URLSession(configuration: config),
                makeStream: { _, options, _ in StreamSession(transport: SyntheticTransport(automatic: true), options: options) },
                requestPermission: { true }, permissionGranted: { true }, activityBegin: { _ in }, activityActive: { true },
                activityUpdate: { _, _ in }, activityEnd: {}, production: sharedKeyboard)
        } catch {
            let model = SessionCoordinator(audio: SyntheticAudio(), production: false)
            model.show(error)
            return model
        }
    }
}

/// The shared-store fixture can only be selected on a simulator with both arguments.
enum KeyboardTestMode {
    static var enabled: Bool {
        #if targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--chirp-ui-test") && args.contains("--chirp-keyboard-host")
        #else
        return false
        #endif
    }
}

struct KeyboardTestHost: View {
    @ObservedObject var model: SessionCoordinator
    @State private var setup = "Preparing synthetic shared session"
    var body: some View {
        VStack {
            Text(setup).accessibilityIdentifier("chirp.host.setup")
            Text(model.phase.rawValue).accessibilityIdentifier("chirp.host.phase")
            LiveKeyboardHost().frame(maxWidth: .infinity, maxHeight: .infinity)
            Button("End fixture session") { model.endSession() }
                .accessibilityIdentifier("chirp.host.end")
        }.padding()
            .task {
                await model.pair(link: "chirp://pair?url=https%3A%2F%2Fsynthetic.test.ts.net%2Fchirp&token=synthetic-only")
                guard model.paired else {
                    setup = "Simulator shared App Group/Keychain unavailable: " + model.notice
                    return
                }
                do {
                    try await model.armSession()
                    setup = "Synthetic shared session armed"
                } catch {
                    setup = "Simulator shared session could not arm: " + error.localizedDescription
                }
            }
    }
}

/// UIKit editor hosts the installed extension; updateUIView never replaces its text.
struct LiveKeyboardHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .title2)
        view.accessibilityIdentifier = "chirp.host.text"
        view.text = "Host prefix. "
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.selectedRange = NSRange(location: view.text.utf16.count, length: 0)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {}
}
#endif
