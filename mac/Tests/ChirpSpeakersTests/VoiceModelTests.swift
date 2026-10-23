import ChirpCore
import Foundation
import Network
import Testing
@testable import ChirpSpeakers

/// An HTTP host that answers every request 200 with the same body and counts requests: a Hub whose files are wrong.
final class WrongFileHost: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "wrong-file-host")
    private let lock = NSLock()
    private var _requests = 0

    init() { listener = try! NWListener(using: .tcp, on: .any) }

    var requests: Int { lock.withLock { _requests } }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                self.lock.withLock { self._requests += 1 }
                let reply = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc"
                c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: queue)
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadUnknown)
    }

    func stop() { listener.cancel() }
}

/// Issue #18 M3: the voice model downloads only after the user's Download, only the pinned files, and a file that
/// does not match its pinned hash is never kept.
@Suite(.serialized) struct VoiceModelTests {
    private func withSandbox(_ registry: String, _ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-voice-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (oldRoot, oldRegistry) = (VoiceModel.root, VoiceModel.registry)
        VoiceModel.root = root
        VoiceModel.registry = registry
        defer { VoiceModel.root = oldRoot; VoiceModel.registry = oldRegistry }
        try await body(root)
    }

    private func files(_ root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter {
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path, isDirectory: &dir) && !dir.boolValue
        }
    }

    @Test func anOfflineLoadMakesNoRequestAndWritesNothing() async throws {
        let host = CountingHost()
        let port = try await host.start()
        defer { host.stop() }
        try await withSandbox("http://127.0.0.1:\(port)") { root in
            #expect(!VoiceModel.isDownloaded() && !VoiceModel.hasFiles())
            await #expect(throws: VoiceModel.LoadError.notDownloaded) { _ = try await VoiceModel.load(download: false) }
            #expect(host.connections == 0 && files(root).isEmpty)
        }
    }

    @Test func aFileThatDoesNotMatchItsHashIsNeverKept() async throws {
        let host = WrongFileHost()
        let port = try await host.start()
        defer { host.stop() }
        try await withSandbox("http://127.0.0.1:\(port)") { root in
            await #expect(throws: VoiceModel.LoadError.checksum("analytics/coremldata.bin")) {
                _ = try await VoiceModel.load(download: true, session: URLSession(configuration: .ephemeral))
            }
            #expect(host.requests == 1 && files(root).isEmpty && !VoiceModel.hasFiles())
        }
    }

    @Test func theManifestIsTheFivePinnedFiles() {
        #expect(VoiceModel.manifest.count == 5 && VoiceModel.manifest.allSatisfy { $0.sha256.count == 64 })
        #expect(VoiceModel.revision.hasPrefix(String(VoiceModel.id.split(separator: "@")[1])))
        #expect(VoiceModel.registry == "https://huggingface.co" || VoiceModel.registry.hasPrefix("http://127.0.0.1"))
        #expect(WeSpeakerModelStore().modelID == VoiceModel.id)
    }
}
