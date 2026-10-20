import Foundation

/// The on-device speaker model, as the Notes window shows it.
public enum SpeakerModelState: Equatable, Sendable {
    case notDownloaded
    /// 0…1.
    case downloading(Double)
    case loading
    case ready
    case failed(String)

    public var isFailure: Bool { if case .failed = self { true } else { false } }
    public var isDownloading: Bool { if case .downloading = self { true } else { false } }
}

/// Where the speaker model lives. Only `load(download: true)`, which follows the user's Download, may use the
/// network; every other load is offline and fails on a missing or damaged model rather than fetching or repairing it.
public protocol SpeakerModelStore: Sendable {
    /// For the consent prompt ("a 106 MB on-device model").
    var sizeText: String { get }
    /// The pinned model is completely on disk.
    func isDownloaded() -> Bool
    /// Any of its files are on disk (complete, partial or damaged): what Remove deletes.
    func hasFiles() -> Bool
    func load(download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> any SpeakerDiarizerFactory
    func remove() throws
}

/// A loaded model: one diarizer per document comes from it.
public protocol SpeakerDiarizerFactory: AnyObject, Sendable {
    func makeDiarizer() -> SpeakerDiarizing
}

/// Live Notes' speaker-label policy: the footer switch, the consent before the one download, offline loads for
/// Record, Remove, and the document's diarizer. Memory only; the switch itself is the one stored preference.
@MainActor
public final class SpeakerLabels {
    public enum Prompt: Equatable, Sendable {
        /// First use: download the model.
        case download(size: String)
        /// The model on disk did not load: remove it and download it again.
        case redownload(size: String)
    }

    /// The user's switch (on only with the model on disk).
    public private(set) var enabled: Bool
    public private(set) var model: SpeakerModelState
    public var onChange: () -> Void = {}
    /// Asks the user; `done(true)` is their Download. Nothing downloads without it.
    public var confirm: (_ prompt: Prompt, _ done: @escaping (Bool) -> Void) -> Void = { _, done in done(false) }

    private let store: SpeakerModelStore
    private let onPreference: (Bool) -> Void
    private var factory: (any SpeakerDiarizerFactory)?
    /// This document's diarizer: Person N stays the same person across Record after Stop.
    public private(set) var diarizer: SpeakerDiarizing?
    private var loadTask: Task<(any SpeakerDiarizerFactory)?, Never>?

    public init(store: SpeakerModelStore, enabled: Bool, onPreference: @escaping (Bool) -> Void) {
        self.store = store
        self.onPreference = onPreference
        let downloaded = store.isDownloaded()
        self.enabled = enabled && downloaded
        model = downloaded ? .ready : .notDownloaded
        if enabled && !downloaded { onPreference(false) }
    }

    public var isLoading: Bool { loadTask != nil }
    /// Record has to load the model first (offline).
    public var needsLoad: Bool { enabled && diarizer == nil && factory == nil }
    /// Settings › Remove applies: files are on disk and nothing is loading them.
    public var canRemove: Bool { loadTask == nil && store.hasFiles() }

    // MARK: the switch

    /// The footer switch. Off cancels a download, and frees the model unless this document already has labels (they
    /// keep their diarizer so Person N stays the same if it is turned on again). On asks before any download.
    public func setEnabled(_ on: Bool, documentHasLabels: Bool) {
        guard on else {
            if model.isDownloading { loadTask?.cancel() }
            setPreference(false)
            if !documentHasLabels { drop() }
            onChange()
            return
        }
        guard loadTask == nil else { return }
        if model.isFailure, store.hasFiles() {
            confirm(.redownload(size: store.sizeText)) { [weak self] yes in
                guard let self, yes else { return }
                try? self.store.remove()
                Task { await self.download() }
            }
        } else if store.isDownloaded() {
            if model.isFailure { model = .ready }
            setPreference(true)
            onChange()
        } else {
            confirm(.download(size: store.sizeText)) { [weak self] yes in
                guard let self, yes else { return }
                Task { await self.download() }
            }
        }
    }

    private func download() async {
        guard await load(download: true) != nil else { return }
        setPreference(true)
        onChange()
    }

    // MARK: Record and New

    /// The diarizer for the next recording without waiting; nil when labels are off or `needsLoad`.
    public func readyDiarizer() -> SpeakerDiarizing? {
        guard enabled else { return nil }
        if let diarizer { return diarizer }
        guard let factory else { return nil }
        diarizer = factory.makeDiarizer()
        return diarizer
    }

    /// Record with labels on: load the model offline if needed. A model that is no longer on disk turns labels off
    /// instead: it never downloads without the user's Download.
    public func prepare() async -> SpeakerDiarizing? {
        guard enabled else { return nil }
        if diarizer == nil, factory == nil {
            guard store.isDownloaded() else {
                setPreference(false)
                model = .notDownloaded
                onChange()
                return nil
            }
            factory = await load(download: false)
        }
        return readyDiarizer()
    }

    /// New: forget this document's speakers and free the model (a warm load takes ~0.1 s).
    public func reset() {
        diarizer?.reset()
        drop()
    }

    /// Settings › Remove. Refused (false) while a load runs on those files.
    @discardableResult
    public func remove() -> Bool {
        guard loadTask == nil else { return false }
        drop()
        try? store.remove()
        setPreference(false)
        model = store.isDownloaded() ? .ready : .notDownloaded
        onChange()
        return true
    }

    // MARK: loading

    private func load(download: Bool) async -> (any SpeakerDiarizerFactory)? {
        if let loadTask { return await loadTask.value }
        model = download ? .downloading(0) : .loading
        onChange()
        let store = self.store
        let task = Task { () -> (any SpeakerDiarizerFactory)? in
            try? await store.load(download: download, progress: { fraction in
                Task { @MainActor [weak self] in self?.progress(fraction) }
            })
        }
        loadTask = task
        let loaded = await task.value
        loadTask = nil
        if let loaded {
            factory = loaded
            model = .ready
        } else if task.isCancelled {
            model = store.isDownloaded() ? .ready : .notDownloaded
        } else {
            model = .failed(download ? "the download failed" : "the model did not load")
            setPreference(false)
        }
        onChange()
        return loaded
    }

    private func progress(_ fraction: Double) {
        guard model.isDownloading else { return }
        model = .downloading(min(max(fraction, 0), 0.99))
        onChange()
    }

    private func setPreference(_ on: Bool) {
        enabled = on
        onPreference(on)
    }

    private func drop() {
        diarizer = nil
        factory = nil
    }
}
