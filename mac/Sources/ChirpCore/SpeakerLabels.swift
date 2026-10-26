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

/// Where the speaker model lives. Only `load(download: true)`, the one-time fetch of the pinned, checksummed model
/// (nothing about the user is sent), may use the network; every other load is offline and fails on a missing or
/// damaged model rather than fetching or repairing it.
public protocol SpeakerModelStore: Sendable {
    /// For the status line ("Getting the speaker model ready (106 MB, once)").
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

/// Live Notes' speaker-label policy: the switch (on unless the user turned it off), the model that follows it
/// (downloaded in the background, never behind a prompt), offline loads for Record, Remove, and the document's
/// diarizer. Memory only; the one stored preference is the user's own choice, so a missing or failed model is a
/// `model` state and never changes the switch.
@MainActor
public final class SpeakerLabels {
    /// The user's switch. On does not mean the model is here: `model` says that.
    public private(set) var enabled: Bool
    public private(set) var model: SpeakerModelState
    public var onChange: () -> Void = {}
    /// The model finished downloading (or loading) with the switch on: a recording in progress joins from here on.
    public var onReady: () -> Void = {}

    private let store: SpeakerModelStore
    private let onPreference: (Bool) -> Void
    private var factory: (any SpeakerDiarizerFactory)?
    /// This document's diarizer: Person N stays the same person across Record after Stop.
    public private(set) var diarizer: SpeakerDiarizing?
    private var loadTask: Task<(any SpeakerDiarizerFactory)?, Never>?

    /// `onPreference` is called only for the user's own choices (the switch, Remove), never for the model's state.
    public init(store: SpeakerModelStore, enabled: Bool, onPreference: @escaping (Bool) -> Void) {
        self.store = store
        self.onPreference = onPreference
        self.enabled = enabled
        model = store.isDownloaded() ? .ready : .notDownloaded
    }

    public var isLoading: Bool { loadTask != nil }
    /// The model's size for the status line ("106 MB"); the store is the one place that knows it.
    public var sizeText: String { store.sizeText }
    /// Record has to load the model first (offline): it is on disk, and nothing holds it yet.
    public var needsLoad: Bool { enabled && diarizer == nil && factory == nil && !model.isFailure && store.isDownloaded() }
    /// Settings › Remove applies: files are on disk and nothing is loading them.
    public var canRemove: Bool { loadTask == nil && store.hasFiles() }

    // MARK: the switch

    /// The switch. Off is the only thing that stores a choice: it cancels a download, and frees the model unless this
    /// document already has labels (they keep their diarizer so Person N stays the same if it is turned on again).
    /// On fetches the model in the background when it is missing, with no prompt.
    public func setEnabled(_ on: Bool, documentHasLabels: Bool) {
        guard on else {
            if model.isDownloading { loadTask?.cancel() }
            if model.isFailure { model = store.isDownloaded() ? .ready : .notDownloaded }
            setPreference(false)
            if !documentHasLabels { drop() }
            onChange()
            return
        }
        setPreference(true)
        if model.isFailure { retry() } else { ensureModel() }
        onChange()
    }

    /// Labels are on and the model is missing: download it in the background. A no-op while one runs, once the model
    /// is on disk, and after a failure (the status line's Retry starts the next attempt).
    public func ensureModel() {
        guard enabled, loadTask == nil, !model.isFailure, !store.isDownloaded() else { return }
        Task { await download() }
    }

    /// Retry on the status line: a damaged or half-downloaded model is removed and fetched again.
    public func retry() {
        guard enabled, loadTask == nil else { return }
        try? store.remove()
        drop()
        model = .notDownloaded
        Task { await download() }
    }

    private func download() async {
        guard await load(download: true) != nil, enabled else { return }
        onChange()
        onReady()
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

    /// Record with labels on: load the model offline if needed. A model that is not on disk starts its download in
    /// the background and Record goes on without labels; they join once it is ready.
    public func prepare() async -> SpeakerDiarizing? {
        guard enabled else { return nil }
        if diarizer == nil, factory == nil {
            guard store.isDownloaded() else {
                if !model.isDownloading, !model.isFailure { model = .notDownloaded }
                ensureModel()
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

    /// Settings › Remove. Refused (false) while a load runs on those files. Removing is the user's choice to stop
    /// labelling: it stores an explicit off, so the model does not come straight back at the next Record.
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
