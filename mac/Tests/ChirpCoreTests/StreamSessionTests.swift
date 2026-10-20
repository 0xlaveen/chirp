import Foundation
import Network
import Testing
@testable import ChirpCore

final class AuthBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// A tiny in-process WebSocket server on loopback that follows the v1 protocol closely enough to test the client.
final class MockServer: @unchecked Sendable {
    enum Script { case normal, rejectAuth }
    /// How one socket behaves, by the order its `start` arrived (0 for the first). Unscripted sockets are normal.
    struct Socket {
        /// Answer `start` with this error code instead of `ready`.
        var refuse: String?
        /// Send this error code on the first audio frame after `ready`.
        var errorOnAudio: String?
        /// Send `correcting` at once on `stop`, then the final after `finalDelay` seconds.
        var correcting = false
        var finalDelay: Double = 0
        /// The final's text instead of the default one.
        var finalText: String?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "mock-server")
    private let lock = NSLock()
    private var _received: [String] = []
    private var _bytes = 0
    private let authBox = AuthBox()
    private var connections: [NWConnection] = []
    private var index: [ObjectIdentifier: Int] = [:]
    private var _bytesBySocket: [Int: Int] = [:]
    private var _sockets: [Int: Socket] = [:]
    private var errored: Set<Int> = []
    let script: Script
    /// Finals read "Segment N." (raw "segment n") instead of "Hello, world.", N being the socket's index.
    var numberedFinals = false

    var received: [String] { lock.withLock { _received } }
    var audioBytes: Int { lock.withLock { _bytes } }
    /// Audio bytes per socket, by start order.
    var bytesBySocket: [Int: Int] { lock.withLock { _bytesBySocket } }
    /// Sockets that sent `start`.
    var started: Int { lock.withLock { index.count } }
    func script(_ socket: Int, _ s: Socket) { lock.withLock { _sockets[socket] = s } }
    var authHeader: String? { authBox.value }

    init(script: Script = .normal) throws {
        self.script = script
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let box = authBox
        ws.setClientRequestHandler(queue) { _, headers in
            box.value = headers.first { $0.name.lowercased() == "authorization" }?.value
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        return try await withCheckedThrowingContinuation { cont in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; cont.resume(returning: listener.port!.rawValue)
                case .failed(let e): resumed = true; cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }

    private func accept(_ c: NWConnection) {
        connections.append(c)
        c.start(queue: queue)
        receive(c)
    }

    private func send(_ c: NWConnection, _ json: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        c.send(content: Data(json.utf8), contentContext: .init(identifier: "t", metadata: [meta]), completion: .idempotent)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if let data, let meta {
                switch meta.opcode {
                case .text:
                    let s = String(decoding: data, as: UTF8.self)
                    lock.withLock { _received.append(s) }
                    handleText(s, c)
                case .binary:
                    let (total, fail) = lock.withLock { () -> (Int, String?) in
                        _bytes += data.count
                        guard let i = index[ObjectIdentifier(c)] else { return (_bytes, nil) }
                        _bytesBySocket[i, default: 0] += data.count
                        guard let code = _sockets[i]?.errorOnAudio, !errored.contains(i) else { return (_bytes, nil) }
                        errored.insert(i)
                        return (_bytes, code)
                    }
                    if let fail {
                        send(c, #"{"type":"error","code":"\#(fail)","message":"scripted"}"#)
                    } else if total >= 3200 {
                        send(c, #"{"type":"partial","seq":1,"text":"hello wor","stable":"hello"}"#)
                    }
                default: break
                }
            }
            receive(c)
        }
    }

    private func handleText(_ s: String, _ c: NWConnection) {
        if s.contains(#""type":"start""#) {
            let socket = lock.withLock { () -> Socket? in
                let i = index.count
                index[ObjectIdentifier(c)] = i
                return _sockets[i]
            }
            if script == .rejectAuth {
                send(c, #"{"type":"error","code":"auth","message":"Bad token"}"#)
            } else if let code = socket?.refuse {
                send(c, #"{"type":"error","code":"\#(code)","message":"scripted"}"#)
            } else {
                send(c, #"{"type":"ready","session":"s1","engine":"mock","debug_retention":true}"#)
            }
        } else if s.contains(#""type":"stop""#) {
            let (i, socket) = lock.withLock { () -> (Int, Socket) in
                let i = index[ObjectIdentifier(c)] ?? 0
                return (i, _sockets[i] ?? Socket())
            }
            let scripted = socket.finalText.flatMap { text in
                (try? JSONSerialization.data(withJSONObject: ["type": "final", "text": text, "raw": text, "corrected": true]))
                    .map { String(decoding: $0, as: UTF8.self) }
            }
            let final = scripted ?? (numberedFinals
                ? #"{"type":"final","text":"Segment \#(i).","raw":"segment \#(i)","corrected":true}"#
                : #"{"type":"final","text":"Hello, world.","raw":"hello world","corrected":true,"timings_ms":{"audio":200,"first_partial":50,"finalize":30}}"#)
            if socket.correcting {
                send(c, #"{"type":"correcting","seq":1,"raw":"segment \#(i)","profile":"default"}"#)
            }
            if socket.finalDelay > 0 {
                queue.asyncAfter(deadline: .now() + socket.finalDelay) { [weak self] in self?.send(c, final) }
            } else {
                send(c, final)
            }
        }
    }
}

@Suite(.serialized) struct StreamSessionTests {
    private func collect(_ session: StreamSession, until done: @Sendable (StreamEvent) -> Bool) async -> [StreamEvent] {
        var out: [StreamEvent] = []
        for await e in session.events {
            out.append(e)
            if done(e) { break }
        }
        return out
    }

    @Test func streamsAudioAndReceivesPartialsAndFinal() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        let config = ServerConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: "tok-123")
        let session = StreamSession(config: config, options: StartOptions(client: "mac", correction: false))
        await session.open()
        for _ in 0..<4 { session.sendAudio(Data(count: 1600)) }          // 6400 bytes of silence
        let consumer = Task {
            await collect(session) { if case .message(.final) = $0 { true } else { false } }
        }
        try await Task.sleep(for: .milliseconds(300))                   // let the frames land first
        await session.stop()
        let events = await consumer.value
        await session.close()

        let messages = events.compactMap { e -> ServerMessage? in if case .message(let m) = e { m } else { nil } }
        #expect(messages.first == .ready(session: "s1", engine: "mock", debugRetention: true))
        #expect(messages.contains(.partial(seq: 1, text: "hello wor", stable: "hello")))
        guard case .final(let f)? = messages.last else { Issue.record("no final"); return }
        #expect(f.text == "Hello, world." && f.raw == "hello world" && f.canUseRaw)
        #expect(f.timings?.firstPartial == 50)

        #expect(server.authHeader == "Bearer tok-123")
        #expect(server.audioBytes == 6400)
        #expect(server.received.first?.contains(#""sample_rate":16000"#) == true)
        #expect(server.received.last == ClientMessage.stop)              // stop only after the last audio frame
    }

    @Test func cancelSendsCancelAndNoFinal() async throws {
        let server = try MockServer()
        let port = try await server.start()
        defer { server.stop() }
        let session = StreamSession(config: ServerConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!), options: StartOptions())
        await session.open()
        session.sendAudio(Data(count: 1600))
        try await Task.sleep(for: .milliseconds(200))
        await session.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.received.contains(ClientMessage.cancel))
        #expect(!server.received.contains(ClientMessage.stop))
    }

    @Test func serverErrorIsSurfaced() async throws {
        let server = try MockServer(script: .rejectAuth)
        let port = try await server.start()
        defer { server.stop() }
        let session = StreamSession(config: ServerConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!), options: StartOptions())
        await session.open()
        let events = await collect(session) { if case .message(.error) = $0 { true } else { false } }
        await session.close()
        #expect(events.last == .message(.error(code: "auth", message: "Bad token")))
    }

    @Test func unreachableServerReportsClosed() async throws {
        // Port 1 on loopback is closed; the connect must fail rather than hang.
        let session = StreamSession(config: ServerConfig(baseURL: URL(string: "http://127.0.0.1:1")!), options: StartOptions())
        await session.open()
        let events = await collect(session) { if case .closed = $0 { true } else { false } }
        #expect(events.last == .closed(reason: "Server unreachable"))
    }
}
