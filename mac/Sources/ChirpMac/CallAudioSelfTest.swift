import AVFoundation
import ChirpCore
import ChirpSpeakers
import ChirpUI
import Foundation

/// `ChirpMac --call-selftest --mic <audio> --remote <audio> [--url URL] [--token-file PATH] [--fast] [--live]
/// [--expect-mic WORD]… [--expect-remote WORD]… [--remote-speakers N] [--snapshot DIR]`
/// Live Notes with call audio (#211) through the real `NotesSession`: the microphone side is a file (as in
/// `--notes-selftest`), and the call side is a file-backed tap played in step with it, resampled to the 48 kHz stereo
/// a process tap delivers, so the mixer, the echo gate, the "You" labels and the remote diarizer all run without the
/// Screen & System Audio Recording permission. `--live` instead plays the remote file through the speakers with
/// `afplay` and records it with the real process tap (on a Mac that has the permission; real time only).
/// Speaker labels use the on-device model already on this Mac (it never downloads). Counts go to stderr; the
/// transcript (the operator asked for it) to stdout. Preferences live in a throwaway suite; the journal is off.
@MainActor
enum CallAudioSelfTest {
    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        func values(_ flag: String) -> [String] {
            args.enumerated().filter { $0.element == flag }.compactMap { args.indices.contains($0.offset + 1) ? args[$0.offset + 1] : nil }
        }
        guard let micPath = value("--mic"), let remotePath = value("--remote") else { return usage() }
        let live = args.contains("--live")
        let fast = args.contains("--fast") && !live
        let remoteSpeakers = value("--remote-speakers").flatMap(Int.init) ?? 2
        guard SpeakerModel.isDownloaded() else {
            print("call-selftest: FAILED — needs the speaker model on this Mac (turn on Label speakers once)")
            return 5
        }
        var config = ServerConfig.load(urlString: value("--url") ?? ServerConfig.defaultURL.absoluteString,
                                       tokenPath: value("--token-file") ?? ServerConfig.defaultTokenPath)
        if let t = ProcessInfo.processInfo.environment["CHIRP_TOKEN"] { config.token = t }
        let server = config

        let frames: [Data]
        let fileTap: FileAudioTap?
        do {
            frames = try SelfTest.loadFrames(micPath)
            fileTap = live ? nil : try FileAudioTap(url: URL(fileURLWithPath: remotePath))
        } catch {
            print("call-selftest: cannot read the audio: \(error.localizedDescription)")
            return 2
        }
        let health: Health
        do { health = try await config.fetchHealth() } catch {
            print("call-selftest: FAILED — no health from \(config.healthURL.absoluteString)")
            return 1
        }
        print("call-selftest: mic \(micPath) + remote \(remotePath) → \(config.baseURL.absoluteString) (\(frames.count * 50) ms, \(live ? "live tap" : "file tap"), \(fast ? "fast" : "real-time"))")

        let suite = "chirp-call-selftest-\(UUID().uuidString)"
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        defer {
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist"))
            try? FileManager.default.removeItem(at: journal)
        }
        prefs.serverURL = config.baseURL.absoluteString
        prefs.correction = false
        prefs.notesRecoveryCopy = false
        // Labels are on by default: the preference stays unset, so this run proves the default too.
        prefs.notesCallAudio = true
        prefs.notesCallAudioExplained = true

        let clock = AudioClock()
        let engine = FileCaptureEngine(frames: frames, fast: fast, clock: clock)
        let tap = CountingTap(live ? CallAudio.makeTap() : fileTap!)
        let player = LivePlayer(path: remotePath)
        if let fileTap {
            engine.beforeBuffer = { fileTap.pump() }
        } else {
            engine.beforeBuffer = { player.startOnce() }
        }
        var deps = NotesSessionDependencies(
            settings: prefs, engine: engine,
            makeSession: { options in
                let task = URLSession.shared.webSocketTask(with: config.authorized(URLRequest(url: config.streamURL)))
                task.maximumMessageSize = 1 << 20
                return StreamSession(transport: FaultTransport(task: task, plan: NotesFaultPlan(), clock: clock), options: options)
            },
            structure: { try await server.structureNotes($0, timeout: NotesController.structureTimeout) },
            reorganize: { try await server.reorganizeNotes($0, timeout: NotesController.reorganizeTimeout) },
            speakerStore: SortformerModelStore(), journalStore: NotesJournalStore(directory: journal))
        deps.startTicker = { _ in {} }
        deps.callTap = tap
        let session = NotesSession(deps)
        session.health = { health }
        session.healthChanged()

        var printed = 0
        session.onChange = {
            let segments = session.recorder.document.segments
            while printed < segments.count {
                let s = segments[printed]
                print("  segment \(printed) @\(String(format: "%.1f", s.offset))s: \(s.failure.map { "⚠︎ gap (\($0))" } ?? s.text)")
                printed += 1
            }
        }

        session.toggle(fromHotkey: true)
        await engine.finished()
        await session.stop()
        while session.isActive { try? await Task.sleep(for: .milliseconds(100)) }
        player.stop()

        let document = session.recorder.document
        let roster = document.roster
        let turns = document.segments.flatMap { $0.turns ?? [] }
        let local = Set(roster.people.filter { $0.local == true }.map(\.id))
        let people = Set(turns.map { roster.resolve($0.person) })
        let remotePeople = people.subtracting(local)
        let youTurns = turns.filter { local.contains(roster.resolve($0.person)) }
        let remoteTurns = turns.filter { !local.contains(roster.resolve($0.person)) }
        print("transcript:")
        for line in document.transcriptLines() { print("  \(line)") }
        FileHandle.standardError.write(Data("call-selftest: segments=\(document.segments.count) gaps=\(document.segments.filter(\.isGap).count) people=\(people.count) you=\(local.isEmpty ? 0 : 1) remote=\(remotePeople.count) turns=\(turns.count) you_turns=\(youTurns.count) remote_turns=\(remoteTurns.count) tap=\(tap.kind.rawValue) tap_buffers=\(tap.buffers) tap_heard=\(tap.heard) state=\(session.recorder.state.logName)\n".utf8))

        if case .error(let message) = session.recorder.state { print("call-selftest: FAILED — \(message)"); return 1 }
        guard tap.buffers > 0, tap.heard else {
            print("call-selftest: FAILED — the call tap delivered \(tap.buffers == 0 ? "nothing" : "only silence")\(live ? " (is Chirp allowed under Screen & System Audio Recording?)" : "")")
            return 12
        }
        let heard = document.segments.map(\.text).joined(separator: " ").lowercased()
        let missing = (values("--expect-mic") + values("--expect-remote")).filter { !heard.contains($0.lowercased()) }
        if !missing.isEmpty { print("call-selftest: FAILED — missing expected words: \(missing.joined(separator: ", "))"); return 3 }
        guard !local.isEmpty, !youTurns.isEmpty else { print("call-selftest: FAILED — the microphone side was never labelled You"); return 6 }
        guard remotePeople.count >= remoteSpeakers else {
            print("call-selftest: FAILED — expected at least \(remoteSpeakers) remote speakers, heard \(remotePeople.count)")
            return 6
        }
        // Each side's words are labelled as that side.
        let youText = youTurns.map(\.text).joined(separator: " ").lowercased()
        let remoteText = remoteTurns.map(\.text).joined(separator: " ").lowercased()
        let misplaced = values("--expect-mic").filter { !youText.contains($0.lowercased()) }
            + values("--expect-remote").filter { !remoteText.contains($0.lowercased()) }
        if !misplaced.isEmpty { print("call-selftest: FAILED — words labelled as the wrong side: \(misplaced.joined(separator: ", "))"); return 7 }
        if let dir = value("--snapshot") {
            let files = (try? Snapshots.render(to: URL(fileURLWithPath: dir), scenarios: [Snapshots.notesScenario("notes-call-selftest", model: session.model, library: session.window)])) ?? []
            FileHandle.standardError.write(Data("call-selftest: snapshots=\(files.count)\n".utf8))
        }
        print("call-selftest: OK")
        return 0
    }

    private static func usage() -> Int32 {
        print("usage: ChirpMac --call-selftest --mic <audio> --remote <audio> [--url URL] [--token-file PATH] [--fast] [--live] [--expect-mic WORD]… [--expect-remote WORD]… [--remote-speakers N] [--snapshot DIR]")
        return 64
    }
}

/// A tap that counts what it delivers: buffers, and whether any was not digital silence.
private final class CountingTap: SystemAudioTap, @unchecked Sendable {
    private let tap: SystemAudioTap
    private let lock = NSLock()
    private var count = 0
    private var loud = false

    init(_ tap: SystemAudioTap) { self.tap = tap }

    var kind: CallAudioKind { tap.kind }
    var buffers: Int { lock.withLock { count } }
    var heard: Bool { lock.withLock { loud } }

    func start(app: CallAudioApp?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        try tap.start(app: app) { [weak self] buffer in
            if let self {
                var peak: Float = 0
                if let data = buffer.floatChannelData {
                    for c in 0..<Int(buffer.format.channelCount) {
                        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[c][i])) }
                    }
                }
                self.lock.withLock { self.count += 1; if peak > 0 { self.loud = true } }
            }
            onBuffer(buffer)
        }
    }

    func stop() { tap.stop() }
}

/// The call side from a file, as a process tap would deliver it: 48 kHz stereo float, 50 ms per `pump()`, then
/// silence (a tap keeps delivering zeros when nothing plays).
final class FileAudioTap: SystemAudioTap, @unchecked Sendable {
    let kind = CallAudioKind.file
    private let lock = NSLock()
    private let chunks: [AVAudioPCMBuffer]
    private let silence: AVAudioPCMBuffer
    private var next = 0
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    static let chunkFrames: AVAudioFrameCount = 2_400

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: Self.format) else { throw CaptureError.converter }
        try file.read(into: source)
        let capacity = AVAudioFrameCount(Double(source.frameLength) * Self.format.sampleRate / file.processingFormat.sampleRate) + 4096
        guard let all = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { throw CaptureError.converter }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: all, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        var chunks: [AVAudioPCMBuffer] = []
        var start: AVAudioFrameCount = 0
        while start < all.frameLength {
            let n = min(Self.chunkFrames, all.frameLength - start)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: Self.chunkFrames) else { break }
            chunk.frameLength = n
            for c in 0..<2 { chunk.floatChannelData![c].update(from: all.floatChannelData![c] + Int(start), count: Int(n)) }
            chunks.append(chunk)
            start += n
        }
        self.chunks = chunks
        silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: Self.chunkFrames)!
        silence.frameLength = Self.chunkFrames
    }

    func start(app: CallAudioApp?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        lock.withLock { self.onBuffer = onBuffer }
    }

    /// The next 50 ms, if capture is on.
    func pump() {
        let (sink, chunk) = lock.withLock { () -> ((@Sendable (AVAudioPCMBuffer) -> Void)?, AVAudioPCMBuffer) in
            guard onBuffer != nil else { return (nil, silence) }
            defer { next += 1 }
            return (onBuffer, next < chunks.count ? chunks[next] : silence)
        }
        sink?(chunk)
    }

    func stop() { lock.withLock { onBuffer = nil } }
}

/// `--live`: plays the remote file through the speakers once the microphone side starts.
private final class LivePlayer: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var process: Process?
    private var started = false

    init(path: String) { self.path = path }

    func startOnce() {
        guard lock.withLock({ () -> Bool in defer { started = true }; return !started }) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [path]
        do { try p.run() } catch { return }
        lock.withLock { process = p }
    }

    func stop() { lock.withLock { process }?.terminate() }
}
