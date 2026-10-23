import Foundation

/// What the Live Notes recovery journal stores for one session: the document (text, tail, segments, roster, start
/// date, dirty flag) and the saved file, if any. No audio. It is plain JSON in a `0700` folder, readable by the user.
public struct NotesJournalRecord: Codable, Equatable, Sendable {
    /// Bumped when the format changes incompatibly; a newer file is ignored (and kept) by an older Chirp.
    public static let schema = 1

    public var schema = NotesJournalRecord.schema
    public var document: NotesDocument
    /// Audio recorded into the document, seconds (new segments continue from here after Keep).
    public var elapsed: TimeInterval
    /// The file Save… last wrote, and whether Chirp keeps it up to date.
    public var savedFile: URL?
    public var keepSaving: Bool
    public var writtenAt: Date

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
        let fm = FileManager.default
        try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let final = file(record.document.id)
        let temp = directory.appendingPathComponent(record.document.id.uuidString + ".json.tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard n > 0 else { throw CocoaError(.fileWriteOutOfSpace) }
                offset += n
            }
        }
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        guard rename(temp.path, final.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
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
            if let header = try? decoder.decode(Header.self, from: data), header.schema > NotesJournalRecord.schema {
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

/// Writes the recovery journal while a Live Notes document has unsaved content, and keeps a saved file up to date
/// when the user asked for that. One `update` call per change of the document is the only hook: changes are written
/// at most every `debounce` (an edit arms a timer; more edits inside it ride along), and at once after a segment
/// commit, an applied AI change, Stop, or the document turning clean. The journal is deleted when the document is
/// clean (Save…), replaced (New) or discarded. The clock and the file work are injected, so tests run on a fake clock.
@MainActor
public final class NotesJournal {
    public static let debounce: Duration = .seconds(2)

    public let store: NotesJournalStore
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

    private enum Op { case write(NotesJournalRecord), delete(UUID) }
    private var ops: [Op] = []
    private var worker: Task<Void, Never>?

    public init(store: NotesJournalStore = NotesJournalStore(), enabled: Bool = true,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.store = store
        self.enabled = enabled
        self.sleep = sleep
    }

    /// Waits for the queued disk work (tests, and quit).
    public func settle() async { await worker?.value }

    // MARK: the one hook

    /// The document may have changed (the controller calls this on every recorder change). `urgent`: an applied AI
    /// change or Stop; a new segment or a document that just turned clean is urgent by itself.
    public func update(_ document: NotesDocument, elapsed: TimeInterval, urgent: Bool = false) {
        var d = document
        d.livePartial = ""
        if d.id != currentID {
            retire()
            currentID = d.id
        }
        let before = latest
        latest = d
        self.elapsed = elapsed
        guard d != before || urgent else { return }
        let committed = d.segments.count > (before?.segments.count ?? 0)
        let cleaned = before?.isDirty == true && !d.isDirty
        if urgent || committed || cleaned {
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
        guard on != enabled else { return }
        enabled = on
        if on { flush() } else { removeJournal() }
    }

    /// Discard: the document's journal goes now (quit with Discard, where no New follows).
    public func discard() {
        timer?.cancel()
        timer = nil
        removeJournal()
    }

    /// A session offered at launch was discarded without being kept.
    public func discard(_ id: UUID) { enqueue(.delete(id)) }

    /// Writes what is pending now.
    public func flush() {
        timer?.cancel()
        timer = nil
        guard let d = latest else { return }
        if let url = savedFile, case .saving = keepStatus, d.exportMarkdown() != lastFiled, writeFile(d, to: url) {
            // The file is the up-to-date copy; marking the document saved removes the journal.
            onKeepSaved?()
            return
        }
        let hasContent = !d.isEmpty || !d.segments.isEmpty
        guard enabled, d.isDirty, hasContent else { return removeJournal() }
        guard d != lastJournaled else { return }
        lastJournaled = d
        wrote = true
        enqueue(.write(NotesJournalRecord(document: d, elapsed: elapsed, savedFile: savedFile, keepSaving: keepStatus.isSaving)))
    }

    // MARK: keep saving

    /// Save… wrote `url`; with `keep` it is rewritten as the document changes.
    public func didSave(to url: URL, keep: Bool) {
        savedFile = url
        lastFiled = latest?.exportMarkdown()
        keepStatus = keep ? .saving(file: url.lastPathComponent) : .off
    }

    public func stopKeepSaving() { keepStatus = .off }

    /// Keep restored a recovered session: its saved file, and whether it is still being kept up to date.
    public func adopt(_ record: NotesJournalRecord) {
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

    /// The previous document was replaced (New): its journal goes, and a saved file is not carried over.
    private func retire() {
        timer?.cancel()
        timer = nil
        removeJournal()
        latest = nil
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
                let bytes = await Task.detached(priority: .utility) { () -> Int? in
                    switch op {
                    case .write(let record): return try? store.write(record)
                    case .delete(let id):
                        store.delete(id)
                        return nil
                    }
                }.value
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
