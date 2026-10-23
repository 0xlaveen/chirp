import ChirpCore
import CryptoKit
@preconcurrency import FluidAudio
import Foundation

/// The on-device speaker model for Live Notes labels: NVIDIA's streaming Sortformer (CC-BY-4.0), converted to CoreML
/// by FluidInference, through FluidAudio (Apache-2.0). It downloads once, from Hugging Face over HTTPS at a pinned
/// revision and only after the user's Download, into `~/Library/Application Support/FluidAudio/Models/sortformer`,
/// and the files are checked against the hashes below. Every other load is offline: a missing or damaged model fails
/// instead of being fetched or repaired (FluidAudio's own purge-and-re-download included).
public enum SpeakerModel {
    public static let repo = "FluidInference/diar-streaming-sortformer-coreml"
    /// The Hugging Face commit the bench measured; a moved `main` can never change what loads.
    public static let revision = "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1"
    /// The only host the model comes from. FluidAudio would take `REGISTRY_URL` / `MODEL_REGISTRY_URL` from the
    /// environment; the app always sets this instead (tests point it at a local server).
    nonisolated(unsafe) static var registry = "https://huggingface.co"
    /// The model cache root; tests use a temporary directory.
    nonisolated(unsafe) static var root: URL?

    /// Weight builds of the same model: fp16 and the 6-bit palettized one (the app's).
    public enum Precision: String, Sendable, CaseIterable {
        case fp16, palettized

        /// What the download prompt says.
        public var sizeText: String { self == .fp16 ? "229 MB" : "106 MB" }
        var fluid: ModelNames.Sortformer.ModelPrecision { self == .fp16 ? .fp16 : .palettized }
    }

    /// Streaming configurations with the same ~1 s latency: `fast` (a 40-frame FIFO) and `balanced` (188 frames of
    /// recent context).
    public enum Variant: String, Sendable, CaseIterable {
        case fast, balanced
    }

    /// The build the app uses: the palettized one matched fp16 on AMI and the synthetic clips at half the download
    /// (docs/bench.md, Speaker labels).
    public static let precision: Precision = .palettized
    public static let variant: Variant = .fast

    /// The app's build at `revision`: each file's size and SHA-256 (the Hub's LFS hashes; the two `model.mil` files
    /// checked against their git blob ids). A download that does not match is deleted.
    static let manifest: [(path: String, size: Int, sha256: String)] = [
        ("analytics/coremldata.bin", 202, "2906b22a79f1d41870fbc9ed0348c9103b06a4794653b6bb0a609bfcd44217b9"),
        ("coremldata.bin", 1091, "96db957cd3c8bb35c1127b2405c360e0e5d2e3a7808b30692f1fb55fd6062719"),
        ("model0/analytics/coremldata.bin", 108, "5a8281049b2a65a3be541cfd9f949e84b8fe1c5251ce90e46da1626fed54e58a"),
        ("model0/coremldata.bin", 632, "c392b563ce501ebe841e1ff7d8a4ff659ee72cdaa6784e16114739feaa37aecc"),
        ("model0/model.mil", 31782, "f6b9b011973f566a8037664418abd87c3c878c2b5bcfaa86d4eceebcfba6b4df"),
        ("model0/weights/0-weight.bin", 8_948_544, "88a98803e35186b1dfb41d7f748f7cee5093bb6efeb117f56953c17549792fa4"),
        ("model1/analytics/coremldata.bin", 108, "5a8281049b2a65a3be541cfd9f949e84b8fe1c5251ce90e46da1626fed54e58a"),
        ("model1/coremldata.bin", 593, "93887e1d6f29e366d58f88efc4caa3b35e189a960db6f91bae3ea5721e3c825d"),
        ("model1/model.mil", 1_220_622, "9b14e85cb0bf274ab646242d9dfbe84ef61cc6956b4d0b203a3fbebc74b40383"),
        ("model1/weights/1-weight.bin", 86_889_664, "ebc39adbaef1d895b0c6f432b5480425fecdfac139fb232ddb21d0dd76b923a8"),
    ]

    public enum LoadError: Error, Equatable {
        /// An offline load found no complete model: only the user's Download may fetch it.
        case notDownloaded
        /// The downloaded files did not match the pinned hashes (they were deleted).
        case checksum(String)
    }

    static func config(_ precision: Precision, _ variant: Variant = variant) -> SortformerConfig {
        var c = variant == .fast ? SortformerConfig.default : SortformerConfig.balancedV2_1
        c.precision = precision.fluid
        return c
    }

    /// FluidAudio's model cache root.
    public static var directory: URL {
        root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    /// This model's folder (both precisions), what Remove deletes.
    public static var folder: URL { directory.appendingPathComponent("sortformer", isDirectory: true) }

    static func bundle(_ precision: Precision, _ variant: Variant = variant) -> URL? {
        ModelNames.Sortformer.bundle(for: config(precision, variant)).map { folder.appendingPathComponent($0) }
    }

    /// The pinned build is completely on disk (revision marker, and every file at its pinned size), so loading it
    /// needs no network and no consent prompt.
    public static func isDownloaded(_ precision: Precision = precision, variant: Variant = variant) -> Bool {
        guard let bundle = bundle(precision, variant) else { return false }
        let marker = folder.appendingPathComponent(".fluidaudio-revision")
        let stored = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored == revision, FileManager.default.fileExists(atPath: bundle.path) else { return false }
        guard precision == Self.precision, variant == Self.variant else { return true }
        return manifest.allSatisfy { file in
            let size = (try? FileManager.default.attributesOfItem(atPath: bundle.appendingPathComponent(file.path).path)[.size]) as? Int
            return size == file.size
        }
    }

    /// Anything of the model on disk: a complete, partial or damaged download.
    public static func hasFiles() -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return !items.isEmpty
    }

    /// Loads the model. With `download` false (every load but the one after the user's Download) FluidAudio runs in
    /// offline mode: nothing is fetched, and a damaged model is not purged and fetched again. `progress` gets 0…1 on
    /// an unspecified queue.
    public static func load(_ precision: Precision = precision, variant: Variant = variant, download: Bool,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> LoadedSpeakerModel {
        ModelRegistry.baseURL = registry
        ModelRegistry.revisionOverrides[repo] = revision
        ModelHub.offlineMode = !download
        defer { ModelHub.offlineMode = true }
        guard download || isDownloaded(precision, variant: variant) else { throw LoadError.notDownloaded }
        var handler: ProgressHandler?
        if let progress { handler = { (update: DownloadProgress) in progress(update.fractionCompleted) } }
        let models = try await SortformerModels.loadFromHuggingFace(config: config(precision, variant),
                                                                     cacheDirectory: directory, progressHandler: handler)
        if download, precision == Self.precision, variant == Self.variant, let bundle = bundle(precision, variant) {
            if let bad = mismatch(in: bundle) {
                try? remove()
                throw LoadError.checksum(bad)
            }
        }
        return LoadedSpeakerModel(models: models, precision: precision, variant: variant)
    }

    /// The first file whose size or SHA-256 differs from the manifest, if any.
    static func mismatch(in bundle: URL) -> String? {
        for file in manifest {
            let url = bundle.appendingPathComponent(file.path)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return file.path }
            defer { try? handle.close() }
            var hasher = SHA256()
            var size = 0
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                size += chunk.count
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if size != file.size || hex != file.sha256 { return file.path }
        }
        return nil
    }

    /// Settings › Remove model: deletes the cached model (both builds, partial downloads too).
    public static func remove() throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }
}

/// The app's `SpeakerModelStore`: the pinned palettized build in FluidAudio's cache.
public struct SortformerModelStore: SpeakerModelStore {
    public init() {}
    public var sizeText: String { SpeakerModel.precision.sizeText }
    public func isDownloaded() -> Bool { SpeakerModel.isDownloaded() }
    public func hasFiles() -> Bool { SpeakerModel.hasFiles() }
    public func load(download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> any SpeakerDiarizerFactory {
        try await SpeakerModel.load(download: download, progress: progress)
    }
    public func remove() throws { try SpeakerModel.remove() }
}

/// A compiled model, ready to start diarizers from (warm loads take ~0.1 s).
public final class LoadedSpeakerModel: SpeakerDiarizerFactory, @unchecked Sendable {
    let models: SortformerModels
    public let precision: SpeakerModel.Precision
    public let variant: SpeakerModel.Variant

    init(models: SortformerModels, precision: SpeakerModel.Precision, variant: SpeakerModel.Variant) {
        self.models = models
        self.precision = precision
        self.variant = variant
    }

    public func makeDiarizer() -> SpeakerDiarizing { makeSortformerDiarizer() }
    public func makeSortformerDiarizer() -> SortformerSpeakerDiarizer { SortformerSpeakerDiarizer(model: self) }
}

/// One Notes document's diarizer: a single streaming Sortformer whose speaker cache keeps Person N the same person
/// for the whole document, across rolling segments and Record after Stop.
///
/// The audio thread only appends frames to a bounded queue (the oldest audio is dropped, and counted, if inference
/// ever falls 30 s behind; it never blocks). A serial background queue converts and runs the model every ~0.5 s.
/// Spans come back in document seconds: every frame carries its document time, so the stopped intervals, the silence
/// padded at Stop and any dropped audio map back exactly.
public final class SortformerSpeakerDiarizer: SpeakerDiarizing, @unchecked Sendable {
    /// Silence fed at Stop so the model's right context settles the last words.
    public static let flushPadding: TimeInterval = 1.5
    /// Most audio waiting for the model before the oldest is dropped.
    public static let maxPending: TimeInterval = 30
    /// The model runs once this much audio waits.
    static let step = 8_000
    static let rate = 16_000.0

    public struct Stats: Sendable, Equatable {
        /// Seconds spent in the model, and seconds of audio it has heard (padding included).
        public var processSeconds: Double = 0
        public var audioSeconds: Double = 0
        public var droppedFrames = 0
        public var errors = 0
    }

    private let diarizer: SortformerDiarizer
    private let queue = DispatchQueue(label: "chirp.speakers", qos: .utility)

    // Shared with the audio thread and readers, under `lock`.
    private let lock = NSLock()
    /// Waiting frames from `head` on: dropping the oldest only moves `head` (the audio thread never shifts the array).
    private var pending: [(pcm: Data, at: TimeInterval)] = []
    private var head = 0
    private var pendingSamples = 0
    private var draining = false
    private var generation = 0
    private var timeline = SpeakerTimeline()
    private var _stats = Stats()

    // The inference queue's own state.
    private struct Piece {
        /// Where the piece starts on the model's clock and in the document; a padding piece stays at `doc`.
        var diar: TimeInterval
        var doc: TimeInterval
        var padding: Bool
    }
    private var pieces: [Piece] = []
    private var samplesFed = 0
    /// The generation the model's state belongs to: a run for a newer one resets the model first, so audio after New
    /// never meets the old speakers (whatever the queue was doing when New came).
    private var modelGeneration = 0

    init(model: LoadedSpeakerModel) {
        var timelineConfig = DiarizerTimelineConfig.sortformerDefault
        // Spans are kept here, in document time; the library keeps no copy and no raw predictions.
        timelineConfig.storeSegments = false
        timelineConfig.maxStoredFrames = 0
        diarizer = SortformerDiarizer(config: SpeakerModel.config(model.precision, model.variant),
                                      timelineConfig: timelineConfig)
        diarizer.initialize(models: model.models)
    }

    public var snapshot: SpeakerTimeline { lock.withLock { timeline } }
    public var stats: Stats { lock.withLock { _stats } }

    public func feed(_ pcm16: Data, at documentTime: TimeInterval) {
        let start = lock.withLock { () -> Bool in
            pending.append((pcm16, documentTime))
            pendingSamples += pcm16.count / 2
            while pendingSamples > Int(Self.maxPending * Self.rate), head < pending.count {
                pendingSamples -= pending[head].pcm.count / 2
                head += 1
                _stats.droppedFrames += 1
            }
            guard !draining, pendingSamples >= Self.step else { return false }
            draining = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    public func flush() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                let (batch, gen) = self.take(all: true)
                self.run(batch, generation: gen, padding: Self.flushPadding)
                done.resume()
            }
        }
    }

    public func reset() {
        lock.withLock {
            generation += 1
            pending.removeAll()
            head = 0
            pendingSamples = 0
            timeline = SpeakerTimeline()
        }
    }

    // MARK: inference queue

    private func drain() {
        while true {
            let (batch, gen) = take(all: false)
            guard !batch.isEmpty else { return }
            run(batch, generation: gen, padding: 0)
        }
    }

    /// The waiting audio; with `all` false, nothing (and the drain ends) until a step's worth is waiting.
    private func take(all: Bool) -> ([(pcm: Data, at: TimeInterval)], Int) {
        lock.withLock {
            guard all || pendingSamples >= Self.step else {
                draining = false
                return ([], generation)
            }
            defer { pending.removeAll(keepingCapacity: true); head = 0; pendingSamples = 0 }
            return (Array(pending[head...]), generation)
        }
    }

    private func run(_ batch: [(pcm: Data, at: TimeInterval)], generation gen: Int, padding: TimeInterval) {
        if gen != modelGeneration {
            diarizer.reset()
            pieces.removeAll()
            samplesFed = 0
            modelGeneration = gen
        }
        var samples: [Float] = []
        samples.reserveCapacity(batch.reduce(0) { $0 + $1.pcm.count / 2 } + Int(padding * Self.rate))
        for (pcm, at) in batch {
            place(at, padding: false)
            pcm.withUnsafeBytes { raw in
                for s in raw.bindMemory(to: Int16.self) { samples.append(Float(s) / 32_768) }
            }
            samplesFed += pcm.count / 2
        }
        if padding > 0 {
            place(nil, padding: true)
            let n = Int(padding * Self.rate)
            samples.append(contentsOf: [Float](repeating: 0, count: n))
            samplesFed += n
        }
        guard !samples.isEmpty else { return }
        let started = Date()
        let update: DiarizerTimelineUpdate?
        var failed = false
        do { update = try diarizer.process(samples: samples) } catch { update = nil; failed = true }
        let elapsed = Date().timeIntervalSince(started)
        lock.withLock {
            _stats.processSeconds += elapsed
            _stats.audioSeconds += Double(samples.count) / Self.rate
            if failed { _stats.errors += 1 }
            guard gen == generation, let update else { return }
            apply(update)
        }
    }

    /// Starts a new piece of the clock map where the document time is not where the model's clock says it should be
    /// (a new recording, dropped audio), or for padding.
    private func place(_ documentTime: TimeInterval?, padding: Bool) {
        let now = Double(samplesFed) / Self.rate
        if padding {
            let doc = pieces.last.map { $0.padding ? $0.doc : $0.doc + (now - $0.diar) } ?? 0
            pieces.append(Piece(diar: now, doc: doc, padding: true))
            return
        }
        guard let documentTime else { return }
        if let last = pieces.last, !last.padding, abs(last.doc + (now - last.diar) - documentTime) < 0.001 { return }
        pieces.append(Piece(diar: now, doc: documentTime, padding: false))
    }

    /// A model time in document seconds (padding collapses to the moment Stop was pressed).
    private func documentTime(_ t: TimeInterval) -> TimeInterval {
        guard let i = pieces.lastIndex(where: { $0.diar <= t + 1e-9 }) else { return t }
        let p = pieces[i]
        let doc = p.padding ? p.doc : p.doc + (t - p.diar)
        return i + 1 < pieces.count ? min(doc, max(pieces[i + 1].doc, p.doc)) : doc
    }

    private func span(_ s: DiarizerSegment) -> SpeakerSpan? {
        let start = documentTime(Double(s.startTime)), end = documentTime(Double(s.endTime))
        return end > start ? SpeakerSpan(slot: s.speakerIndex, start: start, end: end) : nil
    }

    /// Under the lock.
    private func apply(_ update: DiarizerTimelineUpdate) {
        timeline.spans += update.finalizedSegments.compactMap(span)
        timeline.tentative = update.tentativeSegments.compactMap(span)
        let chunk = update.chunkResult
        let frames = chunk.startFrame + chunk.finalizedFrameCount
        timeline.finalizedThrough = max(timeline.finalizedThrough,
                                        documentTime(Double(frames) * Double(diarizer.config.frameDurationSeconds)))
        timeline.prune()
    }
}
