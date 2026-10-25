import AVFoundation
import ChirpCore
import ChirpSpeakers
import ChirpUI
import Foundation

/// `ChirpMac --notes-selftest <audio> [--url URL] [--token-file PATH] [--correction] [--expect WORD]… [--fault PLAN] [--fast]
/// [--speakers N] [--library] [--voices] [--snapshot DIR]`
/// Plays an audio file through the real `NotesSession` (segments over rolling sockets, structuring, Organize) against a
/// server, with no microphone, window or TCC. Preferences live in a throwaway suite and the recovery journal is off,
/// so the app's own state is never touched. Segments, status changes and the final Markdown go to stdout (the
/// operator asked for them); counts go to stderr. `--fault` loses sockets on the client by audio time. `--speakers N`
/// turns on speaker labels with the on-device model already on this Mac (it never downloads), expects exactly N
/// people, then renames Person 2 and checks the name reaches every turn, the export and the structuring transcript.
@MainActor
enum NotesSelfTest {
    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        guard let path = value("--notes-selftest") else { return usage() }
        let expects = args.enumerated().filter { $0.element == "--expect" }.compactMap { args.indices.contains($0.offset + 1) ? args[$0.offset + 1] : nil }
        var plan = NotesFaultPlan()
        if let text = value("--fault") {
            guard let parsed = NotesFaultPlan.parse(text) else {
                print("notes-selftest: bad --fault \(text) (\(NotesFaultPlan.syntax))")
                return 64
            }
            plan = parsed
        }
        var config = ServerConfig.load(urlString: value("--url") ?? ServerConfig.defaultURL.absoluteString,
                                       tokenPath: value("--token-file") ?? ServerConfig.defaultTokenPath)
        if let t = ProcessInfo.processInfo.environment["CHIRP_TOKEN"] { config.token = t }
        let server = config

        let frames: [Data]
        do { frames = try SelfTest.loadFrames(path) } catch {
            print("notes-selftest: cannot read \(path): \(error.localizedDescription)")
            return 2
        }
        let health: Health
        do { health = try await config.fetchHealth() } catch {
            print("notes-selftest: FAILED — no health from \(config.healthURL.absoluteString)")
            return 1
        }
        print("notes-selftest: \(path) → \(config.baseURL.absoluteString) (\(frames.count * 50) ms audio, \(args.contains("--fast") ? "fast" : "real-time"))")

        let suite = "chirp-notes-selftest-\(UUID().uuidString)"
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        defer {
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist"))
            try? FileManager.default.removeItem(at: journal)
        }
        prefs.serverURL = config.baseURL.absoluteString
        prefs.correction = args.contains("--correction")
        prefs.notesRecoveryCopy = false
        let expectSpeakers = value("--speakers").flatMap(Int.init)
        if args.contains("--speakers"), expectSpeakers == nil { return usage() }
        if expectSpeakers != nil, !SpeakerModel.isDownloaded() {
            print("notes-selftest: FAILED — --speakers needs the speaker model on this Mac (turn on Label speakers once)")
            return 5
        }
        prefs.notesSpeakerLabels = expectSpeakers != nil
        // `--library`: the app's notes library in the throwaway directory, as the window uses it (journal writes, the
        // hotkey's new note, reopening a stored note).
        let useLibrary = args.contains("--library")
        // `--voices`: saved-voice suggestions on too (the embedder rides on the diarizer), with profiles in memory only.
        prefs.notesVoiceProfiles = args.contains("--voices")
        if useLibrary { prefs.notesRecoveryCopy = true }

        let clock = AudioClock()
        let engine = FileCaptureEngine(frames: frames, fast: args.contains("--fast"), clock: clock)
        let passes = Counter()
        var deps = NotesSessionDependencies(
            settings: prefs, engine: engine,
            makeSession: { options in
                let task = URLSession.shared.webSocketTask(with: config.authorized(URLRequest(url: config.streamURL)))
                task.maximumMessageSize = 1 << 20
                return StreamSession(transport: FaultTransport(task: task, plan: plan, clock: clock), options: options)
            },
            structure: { passes.add(); return try await server.structureNotes($0, timeout: NotesController.structureTimeout) },
            reorganize: { passes.add(); return try await server.reorganizeNotes($0, timeout: NotesController.reorganizeTimeout) },
            speakerStore: SortformerModelStore(), journalStore: NotesJournalStore(directory: journal))
        deps.startTicker = { _ in {} }
        if args.contains("--voices") { deps.voiceModelStore = WeSpeakerModelStore() }
        if useLibrary { deps.library = NotesLibrary(store: NotesLibraryStore(directory: journal.appendingPathComponent("library"))) }
        let session = NotesSession(deps)
        session.health = { health }
        session.healthChanged()

        let t0 = ContinuousClock.now
        func stamp() -> String {
            let d = ContinuousClock.now - t0
            return "+\(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)ms"
        }
        var lastStatus = "", printed = 0
        session.onChange = {
            let status = session.model.statusText
            if status != lastStatus, !status.isEmpty {
                print("  \(stamp()) status: \(status)")
            }
            lastStatus = status
            // The window reads the rows on every change: the incremental row cache sees each step as it would.
            if expectSpeakers != nil { _ = session.model.transcriptRows }
            let segments = session.recorder.document.segments
            while printed < segments.count {
                let s = segments[printed]
                print("  \(stamp()) segment \(printed) @\(String(format: "%.1f", s.offset))s: \(s.failure.map { "⚠︎ gap (\($0))" } ?? s.text)")
                printed += 1
            }
        }

        session.toggle(fromHotkey: true)
        await engine.finished()
        await session.stop()
        while session.isActive { try? await Task.sleep(for: .milliseconds(100)) }

        let document = session.recorder.document
        print("notes:")
        print(document.text.isEmpty ? "(none: structuring is off on this server)" : document.text)
        print("transcript:")
        for s in document.segments { print("  \(s.failure.map { "⚠︎ gap (\($0))" } ?? s.text)") }
        let gaps = document.segments.filter(\.isGap).count
        let transcript = document.segments.map(\.text).joined(separator: " ")
        FileHandle.standardError.write(Data("notes-selftest: segments=\(document.segments.count) gaps=\(gaps) transcriptChars=\(transcript.count) notesChars=\(document.text.count) passes=\(passes.value) sockets=\(clock.sockets) state=\(session.recorder.state.logName)\n".utf8))

        if case .error(let message) = session.recorder.state, plan.faults.isEmpty {
            print("notes-selftest: FAILED — \(message)")
            return 1
        }
        if document.segments.allSatisfy(\.isGap) { print("notes-selftest: FAILED — nothing transcribed"); return 4 }
        let heard = (transcript + " " + document.text).lowercased()
        let missing = expects.filter { !heard.contains($0.lowercased()) }
        if !missing.isEmpty { print("notes-selftest: FAILED — missing expected words: \(missing.joined(separator: ", "))"); return 3 }
        if let expectSpeakers, let code = checkSpeakers(session, expect: expectSpeakers) { return code }
        if let dir = value("--snapshot") {
            // The real window over the session's own models, drawn offscreen (never shown), light and dark.
            let files = (try? Snapshots.render(to: URL(fileURLWithPath: dir), scenarios: [Snapshots.notesWindow(session, name: "notes-selftest")])) ?? []
            FileHandle.standardError.write(Data("notes-selftest: snapshots=\(files.count)\n".utf8))
        }
        if useLibrary, let code = await checkLibrary(session, expectSpeakers: expectSpeakers) { return code }
        print("notes-selftest: OK")
        return 0
    }

    /// `--speakers N`: exactly N people, then a rename of Person 2 that reaches every one of their turns. Counts only.
    private static func checkSpeakers(_ session: NotesSession, expect: Int) -> Int32? {
        var document = session.recorder.document
        let labelled = document.segments.filter { $0.turns?.isEmpty == false }
        let turns = labelled.flatMap { $0.turns ?? [] }
        let people = Set(turns.map { document.roster.resolve($0.person) }).sorted()
        let changes = zip(turns, turns.dropFirst()).filter { document.roster.resolve($0.person) != document.roster.resolve($1.person) }.count
        FileHandle.standardError.write(Data("notes-selftest: speakers people=\(people.count) labelled=\(labelled.count)/\(document.segments.count) turns=\(turns.count) changes=\(changes) approximate=\(turns.filter(\.approximate).count)\n".utf8))
        guard people.count == expect else {
            print("notes-selftest: FAILED — expected \(expect) speakers, heard \(people.count)")
            return 6
        }
        // The live (incrementally cached) rows show what a fresh build shows.
        let fresh = NotesModel()
        fresh.document = document
        let live = session.model.transcriptRows.map { $0.chip?.name ?? "" }, built = fresh.transcriptRows.map { $0.chip?.name ?? "" }
        let liveChips = Set(live.filter { !$0.isEmpty }).count
        FileHandle.standardError.write(Data("notes-selftest: rows live=\(live.count) chips=\(liveChips) fresh=\(built.count) chips=\(Set(built.filter { !$0.isEmpty }).count)\n".utf8))
        guard live == built, liveChips == expect else {
            print("notes-selftest: FAILED — the live transcript shows \(liveChips) speaker chips, expected \(expect)")
            return 11
        }
        guard expect >= 2 else { return nil }
        let name = "Maya"
        session.editSpeakers(.rename(2, to: name))
        document = session.recorder.document
        let theirs = document.segments.flatMap { $0.turns ?? [] }.filter { document.roster.resolve($0.person) == 2 }
        let export = document.exportMarkdown()
        let lines = document.transcriptLines()
        let named = lines.filter { $0.contains(" \(name):**") }.count
        let structuring = document.segments.map { document.labelledText($0) }.joined(separator: "\n")
        FileHandle.standardError.write(Data("notes-selftest: rename turns=\(theirs.count) lines=\(named) leftover=\(lines.filter { $0.contains(" Person 2:**") }.count)\n".utf8))
        guard !theirs.isEmpty, named > 0, !export.contains("Person 2:"), export.contains("\(name):**"),
              structuring.contains("\(name): "), !structuring.contains("Person 2: ") else {
            print("notes-selftest: FAILED — the rename did not reach every turn, the export and the structuring transcript")
            return 7
        }
        return nil
    }

    /// `--library`: the note as stored is the note as recorded (speakers, names), and it opens again with them.
    private static func checkLibrary(_ session: NotesSession, expectSpeakers: Int?) async -> Int32? {
        guard let library = session.library else { return nil }
        let recorded = session.recorder.document
        session.newNote()
        do { try await session.openNote(recorded.id) } catch {
            print("notes-selftest: FAILED — the note did not open from the library (\(error))")
            return 8
        }
        let stored = try? await library.record(recorded.id).document
        let opened = session.recorder.document
        let people = { (d: NotesDocument) in Set(d.segments.flatMap { $0.turns ?? [] }.map { d.roster.resolve($0.person) }).count }
        let chips = Set(session.model.transcriptRows.compactMap { $0.chip?.name }).count
        FileHandle.standardError.write(Data("notes-selftest: library stored=\(stored.map(people) ?? -1) opened=\(people(opened)) chips=\(chips)\n".utf8))
        guard let stored, stored.segments.map(\.turns) == recorded.segments.map(\.turns),
              (0..<people(recorded)).allSatisfy({ stored.roster.displayName($0 + 1) == recorded.roster.displayName($0 + 1) }),
              opened.segments.map(\.turns) == recorded.segments.map(\.turns) else {
            print("notes-selftest: FAILED — the library lost the speaker labels")
            return 9
        }
        if let expectSpeakers, chips != expectSpeakers {
            print("notes-selftest: FAILED — the reopened note shows \(chips) speaker chips, expected \(expectSpeakers)")
            return 10
        }
        return nil
    }

    private static func usage() -> Int32 {
        print("usage: ChirpMac --notes-selftest <file.wav> [--url URL] [--token-file PATH] [--correction] [--expect WORD]… [--fault \(NotesFaultPlan.syntax)] [--fast] [--speakers N] [--library] [--voices] [--snapshot DIR]")
        return 64
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}

/// Audio seconds fed so far, which is what the fault plan is written in, and how many sockets opened.
final class AudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _seconds: TimeInterval = 0
    private var _sockets = 0
    var seconds: TimeInterval { lock.withLock { _seconds } }
    var sockets: Int { lock.withLock { _sockets } }
    func advance(_ s: TimeInterval) { lock.withLock { _seconds += s } }
    func opened() { lock.withLock { _sockets += 1 } }
}

/// The capture engine for a file: 50 ms buffers of 16 kHz mono audio, in real time (or about 10× with `fast`), then
/// `finished()` returns. No hardware.
final class FileCaptureEngine: CaptureEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let buffers: [AVAudioPCMBuffer]
    private let fast: Bool
    private let clock: AudioClock
    private var block: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var feeder: Task<Void, Never>?
    private let done = AsyncStream<Void>.makeStream()
    /// Runs before each buffer, on the feeder (the call selftest's file-backed tap plays in step with it).
    var beforeBuffer: (@Sendable () -> Void)?
    let inputFormat: AVAudioFormat? = AVAudioFormat(standardFormatWithSampleRate: PCMConverter.sampleRate, channels: 1)

    init(frames: [Data], fast: Bool, clock: AudioClock) {
        self.fast = fast
        self.clock = clock
        let format = AVAudioFormat(standardFormatWithSampleRate: PCMConverter.sampleRate, channels: 1)!
        buffers = frames.compactMap { frame in
            let n = frame.count / 2
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
            b.frameLength = AVAudioFrameCount(n)
            frame.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                for i in 0..<n { b.floatChannelData![0][i] = Float(Int16(littleEndian: s[i])) / 32768 }
            }
            return b
        }
    }

    func installTap(_ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) { lock.withLock { self.block = block } }
    func removeTap() { lock.withLock { block = nil } }
    func prepare() {}
    func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?) {}

    func start() throws {
        guard lock.withLock({ feeder == nil }) else { return }
        let (buffers, fast, clock, done, before) = (self.buffers, self.fast, self.clock, self.done.continuation, self.beforeBuffer)
        let task = Task.detached { [weak self] in
            let start = ContinuousClock.now
            for (i, buffer) in buffers.enumerated() {
                guard let self, let block = self.lock.withLock({ self.block }) else { break }
                before?()
                block(buffer)
                clock.advance(Double(buffer.frameLength) / PCMConverter.sampleRate)
                try? await Task.sleep(until: start + .milliseconds((fast ? 5 : 50) * (i + 1)), clock: .continuous)
            }
            done.yield()
        }
        lock.withLock { feeder = task }
    }

    func stop() {}

    func finished() async { for await _ in done.stream { return } }
}

/// A WebSocket that loses its connection when the fault plan says so (by audio time), as a server restart or a
/// network outage would.
final class FaultTransport: StreamTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let plan: NotesFaultPlan
    private let clock: AudioClock
    private let opened: TimeInterval
    private let lock = NSLock()
    private var lost: URLError?

    init(task: URLSessionWebSocketTask, plan: NotesFaultPlan, clock: AudioClock) {
        self.task = task
        self.plan = plan
        self.clock = clock
        opened = clock.seconds
    }

    func resume() {
        clock.opened()
        task.resume()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if let lost = lock.withLock({ lost }) { throw lost }
        let now = clock.seconds
        if case .string(let s) = message, s.contains(#""type":"start""#), plan.isDown(at: now) { throw lose(.cannotConnectToHost) }
        if plan.drops(opened: opened, now: now) { throw lose(.networkConnectionLost) }
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if let lost = lock.withLock({ lost }) { throw lost }
        return try await task.receive()
    }

    func cancel(with code: URLSessionWebSocketTask.CloseCode) { task.cancel(with: code, reason: nil) }

    private func lose(_ code: URLError.Code) -> URLError {
        let error = URLError(code)
        lock.withLock { lost = error }
        task.cancel(with: .goingAway, reason: nil)
        return error
    }
}
