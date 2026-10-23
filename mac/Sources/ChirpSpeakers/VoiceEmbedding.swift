import ChirpCore
@preconcurrency import CoreML
import CryptoKit
@preconcurrency import FluidAudio
import Foundation

/// The voice-embedding model for Live Notes voice profiles (issue #18 M3): pyannote's WeSpeaker ResNet34 (CC-BY-4.0)
/// as CoreML from FluidInference's `speaker-diarization-coreml`, run through FluidAudio's `EmbeddingExtractor`. Only its
/// five `wespeaker_v2.mlmodelc` files download, once, over HTTPS from Hugging Face at the revision FluidAudio pins,
/// only after the user's Download, and each is checked against the size and SHA-256 below (a mismatch is deleted).
/// Every other load is offline.
public enum VoiceModel {
    public static let repo = "FluidInference/speaker-diarization-coreml"
    public static let revision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    public static let bundleName = "wespeaker_v2.mlmodelc"
    /// What profiles record: a different model (or revision) makes them incompatible, never compared.
    public static let id = "wespeaker_v2@df2625a"
    nonisolated(unsafe) static var registry = "https://huggingface.co"
    nonisolated(unsafe) static var root: URL?
    public static let sizeText = "8 MB"

    /// The Hub's LFS hashes, and the two plain files hashed from the same revision.
    static let manifest: [(path: String, size: Int, sha256: String)] = [
        ("analytics/coremldata.bin", 243, "d2b1fcde6121aea3ff0e14c1dc50d09dacb0314a2e89156353c31804230a422f"),
        ("coremldata.bin", 359, "6feb2472a71fa9d8a84020c85206138a4f6261c565c9884bf518d59dd5838da7"),
        ("metadata.json", 2738, "ddc4858b4051254098015cd0b97080149839d697faf7b036f933190e70b26758"),
        ("model.mil", 706_900, "2850f775d6ba659f01f616fed77ce6a45a25de3eb7e4bf3a4b07b658be4e13dd"),
        ("weights/weight.bin", 7_243_904, "34004f6798d35cad7071e2fdc67e63faaa782f53697e1cb49bcb452cf81ae151"),
    ]

    public enum LoadError: Error, Equatable {
        case notDownloaded
        case checksum(String)
        case http(String)
    }

    public static var directory: URL {
        root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    /// What Remove deletes.
    public static var folder: URL { directory.appendingPathComponent("voice-embedding", isDirectory: true) }
    static var bundle: URL { folder.appendingPathComponent(bundleName, isDirectory: true) }

    /// Every pinned file is on disk at its pinned size.
    public static func isDownloaded() -> Bool {
        manifest.allSatisfy { file in
            let size = (try? FileManager.default.attributesOfItem(atPath: bundle.appendingPathComponent(file.path).path)[.size]) as? Int
            return size == file.size
        }
    }

    public static func hasFiles() -> Bool { !((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty }

    public static func remove() throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Loads the model; with `download` (the user's Download) it first fetches and checks the pinned files.
    public static func load(download: Bool, session: URLSession = .shared,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> WeSpeakerEmbedder {
        if download, !isDownloaded() { try await fetch(session: session, progress: progress) }
        guard isDownloaded() else { throw LoadError.notDownloaded }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let model = try await MLModel.load(contentsOf: bundle, configuration: config)
        return WeSpeakerEmbedder(model: model)
    }

    /// Downloads the five files into a temporary folder, checks each, then moves the bundle into place.
    static func fetch(session: URLSession, progress: (@Sendable (Double) -> Void)?) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let total = Double(manifest.reduce(0) { $0 + $1.size })
        var done = 0.0
        for file in manifest {
            try Task.checkCancellation()
            guard let url = URL(string: "\(registry)/\(repo)/resolve/\(revision)/\(bundleName)/\(file.path)") else {
                throw LoadError.http(file.path)
            }
            let (temp, response) = try await session.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LoadError.http(file.path) }
            let target = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: temp, to: target)
            guard let data = try? Data(contentsOf: target), data.count == file.size,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw LoadError.checksum(file.path)
            }
            done += Double(file.size)
            progress?(done / total)
        }
        try? fm.removeItem(at: bundle)
        try fm.moveItem(at: staging, to: bundle)
    }
}

/// The app's `VoiceModelStore`.
public struct WeSpeakerModelStore: VoiceModelStore {
    public init() {}
    public var modelID: String { VoiceModel.id }
    public var sizeText: String { VoiceModel.sizeText }
    public func isDownloaded() -> Bool { VoiceModel.isDownloaded() }
    public func hasFiles() -> Bool { VoiceModel.hasFiles() }
    public func load(download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> any VoiceEmbedder {
        try await VoiceModel.load(download: download, progress: progress)
    }
    public func remove() throws { try VoiceModel.remove() }
}

/// WeSpeaker over up to 10 s of one voice: the whole clip is that speaker (an all-ones mask).
public final class WeSpeakerEmbedder: VoiceEmbedder, @unchecked Sendable {
    /// The model's window: 10 s at 16 kHz.
    public static let window = 160_000
    private let extractor: EmbeddingExtractor
    private let maskFrames: Int
    private let lock = NSLock()

    init(model: MLModel) {
        extractor = EmbeddingExtractor(embeddingModel: model)
        maskFrames = model.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.shape.last?.intValue ?? 589
    }

    public func embedding(_ samples: [Float]) throws -> [Float] {
        // The extractor loop-pads a shorter clip (and its mask) to the window, as FluidAudio's own
        // `extractSpeakerEmbedding` relies on.
        let clip = Array(samples.suffix(Self.window))
        let mask = [Float](repeating: 1, count: maskFrames)
        let out = try lock.withLock { try extractor.getEmbeddings(audio: clip, masks: [mask]) }
        return Voiceprint(sum: out.first ?? [], seconds: 1).centroid
    }
}
