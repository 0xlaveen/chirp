import Foundation

/// A schema-versioned local note snapshot, including text, capture boundaries, audio references and export options.
/// Legacy recovery journals and sealed iOS records use the same backward-compatible envelope.
public struct NotesJournalRecord: Codable, Equatable, Sendable {
    /// Bumped when the format changes incompatibly; a newer file is ignored (and kept) by an older Chirp.
    public static let schema = 2

    public var schema = NotesJournalRecord.schema
    public var document: NotesDocument
    /// Audio recorded into the document, seconds (new segments continue from here after Keep).
    public var elapsed: TimeInterval
    /// The file Save… last wrote, and whether Chirp keeps it up to date.
    public var savedFile: URL?
    public var keepSaving: Bool
    public var writtenAt: Date
    /// Present in library records; nil in schema 1 recovery journals.
    public var recording: Bool?
    public var recovered: Bool?

    public init(document: NotesDocument, elapsed: TimeInterval, savedFile: URL? = nil, keepSaving: Bool = false,
                writtenAt: Date = Date()) {
        self.document = document
        self.elapsed = elapsed
        self.savedFile = savedFile
        self.keepSaving = keepSaving
        self.writtenAt = writtenAt
    }
}

/// Seals a journal file's bytes before they reach the disk and opens them again (iOS: AES-GCM with a Keychain key).
public struct NotesJournalCodec: Sendable {
    public var seal: @Sendable (Data) throws -> Data
    public var open: @Sendable (Data) throws -> Data

    public init(seal: @escaping @Sendable (Data) throws -> Data, open: @escaping @Sendable (Data) throws -> Data) {
        self.seal = seal
        self.open = open
    }
}

/// The journal folder: `<session-id>.json` per session, written atomically (a temp file, then a rename) so a torn
/// write never shadows the good file. Safe to call from any thread. With a `codec` every file is sealed by it.
public struct NotesJournalStore: Sendable {
    public let directory: URL
    public let codec: NotesJournalCodec?

    public init(directory: URL = Self.defaultDirectory, codec: NotesJournalCodec? = nil) {
        self.directory = directory
        self.codec = codec
    }

    /// `~/Library/Application Support/Chirp/Recovery`.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chirp", isDirectory: true).appendingPathComponent("Recovery", isDirectory: true)
    }

    func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    /// Writes the record (folder `0700`, file `0600`, flushed to the drive before the rename). Returns its size.
    @discardableResult
    public func write(_ record: NotesJournalRecord) throws -> Int {
        let json = try JSONEncoder().encode(record)
        let data = try codec?.seal(json) ?? json
        try NotesAtomicFile.write(data, to: file(record.document.id))
        return data.count
    }

    public func delete(_ id: UUID) { try? FileManager.default.removeItem(at: file(id)) }

    /// The sessions a launch can offer, newest first. A file from a newer schema, or one that does not decode, is
    /// skipped and left on disk (with a counts-only log line); stray temp files from a torn write are removed.
    public func recoverable() -> [NotesJournalRecord] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        struct Header: Decodable { var schema: Int }
        var found: [NotesJournalRecord] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            if name.hasSuffix(".json.tmp") { try? fm.removeItem(at: url); continue }
            guard name.hasSuffix(".json"), let stored = try? Data(contentsOf: url) else { continue }
            guard let data = codec == nil ? stored : try? codec?.open(stored) else {
                chirpLog.info("notes journal unreadable bytes=\(stored.count, privacy: .public)")
                continue
            }
            let decoder = JSONDecoder()
            if let header = try? decoder.decode(Header.self, from: data), ![1, NotesJournalRecord.schema].contains(header.schema) {
                chirpLog.info("notes journal ignored schema=\(header.schema, privacy: .public) supported=\(NotesJournalRecord.schema, privacy: .public)")
                continue
            }
            guard let record = try? decoder.decode(NotesJournalRecord.self, from: data) else {
                chirpLog.info("notes journal unreadable bytes=\(data.count, privacy: .public)")
                continue
            }
            found.append(record)
        }
        return found.sorted { $0.writtenAt > $1.writtenAt }
    }
}

/// Whether a saved file is being kept up to date.
public enum KeepSavingStatus: Equatable, Sendable {
    case off
    case saving(file: String)
    case stopped(String)

    public static let moved = "Stopped saving — file moved"
    public static let failed = "Stopped saving — couldn’t write the file"

    /// The footer's line, nil when nothing is kept.
    public var text: String? {
        switch self {
        case .off: nil
        case .saving(let file): "Saving to \(file)"
        case .stopped(let why): why
        }
    }
}

/// Debounced document writer. Mac passes a library, which keeps clean/exported/replaced notes. Clients without a
/// library retain the legacy transient recovery journal. Text and segment audio disk work is queued in order;
/// a segment commit, AI change, capture transition or export flushes immediately. Time and storage are injectable.
@MainActor
public final class NotesJournal {
    public static let debounce: Duration = .seconds(2)

    public let store: NotesJournalStore
    public let library: NotesLibrary?
    private var recording = false
    private let sleep: @Sendable (Duration) async -> Void
    private let fileManager = FileManager.default

    /// A journal write finished: its size (nil when it failed) and duration. For the counts-only log.
    public var onWrite: ((_ bytes: Int?, _ ms: Int) -> Void)?
    /// Keep saving wrote the file, so the document may be marked saved; or it stopped (the footer shows why).
    public var onKeepSaved: (() -> Void)?
    public var onKeepChange: (() -> Void)?

    public private(set) var enabled: Bool
    public private(set) var keepStatus: KeepSavingStatus = .off { didSet { if keepStatus != oldValue { onKeepChange?() } } }
    /// The last file Save… wrote for this document.
    public private(set) var savedFile: URL?

    private var currentID: UUID?
    private var wrote = false
    private var latest: NotesDocument?
    private var elapsed: TimeInterval = 0
    private var lastJournaled: NotesDocument?
    /// The export the saved file holds.
    private var lastFiled: String?
    private var timer: Task<Void, Never>?

    private enum Op {
        case write(NotesJournalRecord), delete(UUID)
        case audio(UUID, Int, [Data], TimeInterval, Double)
    }
    private var ops: [Op] = []
    private var worker: Task<Void, Never>?

    public init(store: NotesJournalStore = NotesJournalStore(), enabled: Bool = true, library: NotesLibrary? = nil,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.store = store
        self.library = library
        self.enabled = library != nil || enabled
        self.sleep = sleep
    }

    /// Waits for the queued disk work (tests, and quit).
    public func settle() async { await worker?.value }

    // MARK: the one hook

    /// The document may have changed (the controller calls this on every recorder change). `urgent`: an applied AI
    /// change or Stop; a new segment or a document that just turned clean is urgent by itself.
    public func update(_ document: NotesDocument, elapsed: TimeInterval, urgent: Bool = false, recording: Bool = false) {
        let stateChanged = self.recording != recording
        var d = document
        d.livePartial = ""
        if d.id != currentID {
            retire()
            currentID = d.id
        }
        self.recording = recording
        let before = latest
        latest = d
        self.elapsed = elapsed
        guard d != before || urgent || stateChanged else { return }
        let committed = d.segments.count > (before?.segments.count ?? 0)
        let cleaned = before?.isDirty == true && !d.isDirty
        if urgent || committed || cleaned || stateChanged {
            flush()
        } else if timer == nil {
            timer = Task { [sleep] in
                await sleep(Self.debounce)
                guard !Task.isCancelled else { return }
                self.flush()
            }
        }
    }

    /// "Keep a recovery copy until notes are saved": off deletes the copy now, on writes it now.
    public func setEnabled(_ on: Bool) {
        guard library == nil, on != enabled else { return }
        enabled = on
        if on { flush() } else { removeJournal() }
    }

    /// Discard: the document's journal goes now (quit with Discard, where no New follows).
    public func discard() {
        timer?.cancel()
        timer = nil
        if library != nil { flush() } else { removeJournal() }
    }

    /// A session offered at launch was discarded without being kept.
    public func discard(_ id: UUID) { if library == nil { enqueue(.delete(id)) } }

    /// Writes what is pending now.
    public func flush() {
        timer?.cancel()
        timer = nil
        guard let d = latest else { return }
        if let url = savedFile, case .saving = keepStatus, d.exportMarkdown() != lastFiled, writeFile(d, to: url) {
            // The export is up to date. Library persistence continues independently.
            onKeepSaved?()
            if library == nil { return }
        }
        let hasContent = !d.isEmpty || !d.segments.isEmpty || (library != nil && (d.userTitle != nil || d.version > 0))
        guard enabled, (library != nil || d.isDirty), hasContent || (library != nil && (recording || wrote)) else {
            if library == nil { removeJournal() }
            return
        }
        guard d != lastJournaled || library != nil else { return }
        lastJournaled = d
        wrote = true
        var record = NotesJournalRecord(document: d, elapsed: elapsed, savedFile: savedFile, keepSaving: keepStatus.isSaving)
        record.recording = library == nil ? nil : recording
        enqueue(.write(record))
    }

    /// Queued with text writes, so the segment exists before its audio metadata is committed.
    public func keepAudio(_ id: UUID, segment: Int, frames: [Data], offset: TimeInterval, sampleRate: Double) {
        guard library != nil, !frames.isEmpty else { return }
        enqueue(.audio(id, segment, frames, offset, sampleRate))
    }

    // MARK: keep saving

    /// Save… wrote `url`; with `keep` it is rewritten as the document changes.
    public func didSave(to url: URL, keep: Bool) {
        savedFile = url
        lastFiled = latest?.exportMarkdown()
        keepStatus = keep ? .saving(file: url.lastPathComponent) : .off
        if library != nil { flush() }
    }

    public func stopKeepSaving() { keepStatus = .off }

    /// Keep restored a recovered session: its saved file, and whether it is still being kept up to date.
    public func adopt(_ record: NotesJournalRecord) {
        if library != nil { flush(); latest = record.document; elapsed = record.elapsed; recording = false }
        currentID = record.document.id
        wrote = true
        lastJournaled = nil
        lastFiled = nil
        savedFile = record.savedFile
        guard record.keepSaving, let url = record.savedFile else { keepStatus = .off; return }
        keepStatus = fileManager.fileExists(atPath: url.path) ? .saving(file: url.lastPathComponent) : .stopped(KeepSavingStatus.moved)
    }

    private func writeFile(_ d: NotesDocument, to url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            keepStatus = .stopped(KeepSavingStatus.moved)
            return false
        }
        let text = d.exportMarkdown()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            keepStatus = .stopped(KeepSavingStatus.failed)
            return false
        }
        lastFiled = text
        return true
    }

    // MARK: disk work, in order

    /// Replacing a document flushes it to the library and stops its keep-updated export.
    private func retire() {
        timer?.cancel()
        timer = nil
        if library != nil { flush() } else { removeJournal() }
        latest = nil
        lastJournaled = nil
        lastFiled = nil
        savedFile = nil
        keepStatus = .off
    }

    private func removeJournal() {
        lastJournaled = nil
        guard wrote, let id = currentID else { return }
        wrote = false
        enqueue(.delete(id))
    }

    private func enqueue(_ op: Op) {
        switch op {
        case .audio: break
        case .write(let record):
            if case .write(let last)? = ops.last, last.document.id == record.document.id { ops.removeLast() }
        case .delete(let id):
            ops.removeAll { if case .write(let r) = $0 { r.document.id == id } else { false } }
        }
        ops.append(op)
        guard worker == nil else { return }
        worker = Task {
            while !ops.isEmpty {
                let op = ops.removeFirst()
                let store = self.store
                let start = ContinuousClock.now
                let bytes: Int?
                if let library {
                    switch op {
                    case .write(let record): bytes = try? await library.write(record)
                    case .delete: bytes = nil
                    case .audio(let id, let segment, let frames, let offset, let rate):
                        try? await library.keepAudio(id, segment: segment, frames: frames, offset: offset, sampleRate: rate)
                        bytes = nil
                    }
                } else {
                    bytes = await Task.detached(priority: .utility) { () -> Int? in
                        switch op {
                        case .write(let record): return try? store.write(record)
                        case .delete(let id): store.delete(id); return nil
                        case .audio: return nil
                        }
                    }.value
                }
                if case .write = op {
                    let e = (ContinuousClock.now - start).components
                    onWrite?(bytes, Int(Double(e.seconds) * 1000 + Double(e.attoseconds) / 1e15))
                }
            }
            worker = nil
        }
    }
}

extension KeepSavingStatus {
    public var isSaving: Bool { if case .saving = self { true } else { false } }
}
