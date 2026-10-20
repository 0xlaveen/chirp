import ChirpCore
@preconcurrency import FluidAudio
import Foundation

/// The on-device speaker model for Live Notes labels: NVIDIA's streaming Sortformer (CC-BY-4.0) as CoreML, through
/// FluidAudio (Apache-2.0). It downloads once from Hugging Face at a pinned revision, after the user's explicit
/// consent, into `~/Library/Application Support/FluidAudio/Models/sortformer`; inference never needs the network.
public enum SpeakerModel {
    public static let repo = "FluidInference/diar-streaming-sortformer-coreml"
    /// The Hugging Face commit the bench measured; a moved `main` can never change what loads.
    public static let revision = "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1"

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

    static func config(_ precision: Precision, _ variant: Variant = variant) -> SortformerConfig {
        var c = variant == .fast ? SortformerConfig.default : SortformerConfig.balancedV2_1
        c.precision = precision.fluid
        return c
    }

    /// FluidAudio's model cache root.
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    /// This model's folder (both precisions), what Remove deletes.
    public static var folder: URL { directory.appendingPathComponent("sortformer", isDirectory: true) }

    /// The pinned build is on disk, so loading it needs no network (and no consent prompt).
    public static func isDownloaded(_ precision: Precision = precision) -> Bool {
        guard let bundle = ModelNames.Sortformer.bundle(for: config(precision)) else { return false }
        let fm = FileManager.default
        let marker = folder.appendingPathComponent(".fluidaudio-revision")
        let stored = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored == revision && fm.fileExists(atPath: folder.appendingPathComponent(bundle).path)
    }

    /// Downloads (once) and compiles the model. `progress` gets 0…1 on an unspecified queue.
    public static func load(_ precision: Precision = precision, variant: Variant = variant,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> LoadedSpeakerModel {
        ModelRegistry.revisionOverrides[repo] = revision
        var handler: ProgressHandler?
        if let progress { handler = { (update: DownloadProgress) in progress(update.fractionCompleted) } }
        let models = try await SortformerModels.loadFromHuggingFace(config: config(precision, variant),
                                                                     cacheDirectory: directory, progressHandler: handler)
        return LoadedSpeakerModel(models: models, precision: precision, variant: variant)
    }

    /// Settings › Remove model: deletes the cached model (both builds).
    public static func remove() throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }
}

/// A compiled model, ready to start diarizers from (warm loads take ~0.1 s).
public final class LoadedSpeakerModel: @unchecked Sendable {
    let models: SortformerModels
    public let precision: SpeakerModel.Precision
    public let variant: SpeakerModel.Variant

    init(models: SortformerModels, precision: SpeakerModel.Precision, variant: SpeakerModel.Variant) {
        self.models = models
        self.precision = precision
        self.variant = variant
    }

    public func makeDiarizer() -> SortformerSpeakerDiarizer { SortformerSpeakerDiarizer(model: self) }
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
    private var pending: [(pcm: Data, at: TimeInterval)] = []
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
            while pendingSamples > Int(Self.maxPending * Self.rate), let first = pending.first {
                pending.removeFirst()
                pendingSamples -= first.pcm.count / 2
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
            pendingSamples = 0
            timeline = SpeakerTimeline()
        }
        queue.async {
            self.diarizer.reset()
            self.pieces.removeAll()
            self.samplesFed = 0
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
            defer { pending.removeAll(keepingCapacity: true); pendingSamples = 0 }
            return (pending, generation)
        }
    }

    private func run(_ batch: [(pcm: Data, at: TimeInterval)], generation gen: Int, padding: TimeInterval) {
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
    }
}
