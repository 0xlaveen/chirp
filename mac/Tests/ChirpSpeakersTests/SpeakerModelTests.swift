import ChirpCore
import Foundation
import Network
import Testing
@testable import ChirpSpeakers

/// An HTTP host that answers every request 404 and counts connections: standing in for Hugging Face, it shows
/// whether a load touched the network at all.
final class CountingHost: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "counting-host")
    private let lock = NSLock()
    private var _connections = 0

    init() { listener = try! NWListener(using: .tcp, on: .any) }

    var connections: Int { lock.withLock { _connections } }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.lock.withLock { self._connections += 1 }
            c.start(queue: self.queue)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
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

/// Review B1: the model downloads only after the user's Download. Every other load is offline, so a missing model
/// fails without a request, and a damaged one is neither deleted nor fetched again.
@Suite(.serialized) struct SpeakerModelConsentTests {
    private func withSandbox(_ body: (URL, CountingHost) async throws -> Void) async throws {
        let host = CountingHost()
        let port = try await host.start()
        defer { host.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-speaker-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (oldRoot, oldRegistry) = (SpeakerModel.root, SpeakerModel.registry)
        SpeakerModel.root = root
        SpeakerModel.registry = "http://127.0.0.1:\(port)"
        defer { SpeakerModel.root = oldRoot; SpeakerModel.registry = oldRegistry }
        try await body(root, host)
    }

    private func files(_ root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted()
    }

    @Test func anOfflineLoadOfAMissingModelMakesNoRequestAndWritesNothing() async throws {
        try await withSandbox { root, host in
            #expect(!SpeakerModel.isDownloaded() && !SpeakerModel.hasFiles())
            await #expect(throws: SpeakerModel.LoadError.notDownloaded) {
                _ = try await SpeakerModel.load(download: false)
            }
            #expect(host.connections == 0)
            #expect(files(root).isEmpty)
        }
    }

    @Test func aDamagedModelIsNotPurgedOrFetchedAgainOffline() async throws {
        try await withSandbox { root, host in
            // Every file at its pinned size, but garbage: CoreML cannot load it.
            let bundle = try #require(SpeakerModel.bundle(SpeakerModel.precision))
            for file in SpeakerModel.manifest {
                let url = bundle.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(file.size))
                try handle.close()
            }
            try SpeakerModel.revision.write(to: SpeakerModel.folder.appendingPathComponent(".fluidaudio-revision"),
                                            atomically: true, encoding: .utf8)
            #expect(SpeakerModel.isDownloaded())
            let before = files(root)
            await #expect(throws: (any Error).self) { _ = try await SpeakerModel.load(download: false) }
            #expect(host.connections == 0)
            #expect(files(root) == before)                 // not purged
            #expect(SpeakerModel.mismatch(in: bundle) != nil)
        }
    }

    @Test func onlyAConsentedDownloadReachesTheHostAndItIsThePinnedOne() async throws {
        try await withSandbox { _, host in
            await #expect(throws: (any Error).self) { _ = try await SpeakerModel.load(download: true) }
            #expect(host.connections > 0)
            // Offline is the state every other load runs in.
            await #expect(throws: SpeakerModel.LoadError.notDownloaded) { _ = try await SpeakerModel.load(download: false) }
        }
    }

    @Test func aPartialDownloadIsNotDownloadedButCanBeRemoved() async throws {
        try await withSandbox { _, host in
            let partial = SpeakerModel.folder.appendingPathComponent("v3/palettized/Sortformer_v2.1.mlmodelc/coremldata.bin.partial")
            try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: partial)
            #expect(!SpeakerModel.isDownloaded() && SpeakerModel.hasFiles())
            let store = SortformerModelStore()
            #expect(store.hasFiles())
            try store.remove()
            #expect(!SpeakerModel.hasFiles() && host.connections == 0)
        }
    }

    @Test func theAppAlwaysUsesTheHTTPSHubWhateverTheEnvironmentSays() {
        // Tests set `registry` explicitly; the shipped default is fixed, and `load` writes it over FluidAudio's
        // environment-derived base URL every time.
        #expect(SpeakerModel.registry.hasPrefix("https://huggingface.co") || SpeakerModel.registry.hasPrefix("http://127.0.0.1"))
        #expect(SpeakerModel.manifest.count == 10 && SpeakerModel.manifest.allSatisfy { $0.sha256.count == 64 })
    }
}
