#if DEBUG
import AVFoundation
import ChirpCore
import ChirpIOSCore
import Foundation

/// Synthetic capture: quiet 50 ms frames at real-time pace. Not compiled into Release.
@MainActor
final class SyntheticNotesAudio: NotesAudio {
    private var feeder: Task<Void, Never>?
    private(set) var starts = 0
    private(set) var event: (@Sendable (NotesAudioEvent) -> Void)?
    var isRunning: Bool { feeder != nil }
    var fails = false
    func start(frame: @escaping @Sendable (Data) -> Void, event: @escaping @Sendable (NotesAudioEvent) -> Void) throws {
        guard !fails else { throw SessionFailure.audio }
        starts += 1
        self.event = event
        feeder?.cancel()
        feeder = Task.detached {
            var samples = [Int16](repeating: 0, count: PCMConverter.frameBytes / 2)
            for i in samples.indices { samples[i] = Int16(i % 2 == 0 ? 600 : -600) }
            let data = samples.withUnsafeBytes { Data($0) }
            while !Task.isCancelled {
                frame(data)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
    func stop() { feeder?.cancel(); feeder = nil }
}

/// Simulator-only speech for Live Notes against a real local server (`--chirp-sim-audio <file>`, see
/// `SimulatorFileAudio`): the file once at real-time pace, then silence until Pause or Stop. Silent looping playback
/// keeps the app running in the background, as the microphone does on a device.
@MainActor
final class SimulatorNotesAudio: NotesAudio {
    private let url: URL
    private let keepAlive = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var feeder: Task<Void, Never>?
    var isRunning: Bool { feeder != nil }
    init(url: URL) { self.url = url }
    static func fromArguments() -> SimulatorNotesAudio? {
        #if targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--chirp-sim-audio"), i + 1 < args.count else { return nil }
        let path = args[i + 1]
        return SimulatorNotesAudio(url: path.hasPrefix("/") ? URL(fileURLWithPath: path) : FileManager.default.temporaryDirectory.appendingPathComponent(path))
        #else
        return nil
        #endif
    }
    func start(frame: @escaping @Sendable (Data) -> Void, event: @escaping @Sendable (NotesAudioEvent) -> Void) throws {
        guard feeder == nil, let file = try? AVAudioFile(forReading: url), PCMConverter(from: file.processingFormat) != nil else { throw SessionFailure.audio }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            let format = keepAlive.mainMixerNode.outputFormat(forBus: 0)
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { throw SessionFailure.audio }
            silence.frameLength = silence.frameCapacity
            if player.engine == nil { keepAlive.attach(player) }
            keepAlive.connect(player, to: keepAlive.mainMixerNode, format: format)
            player.scheduleBuffer(silence, at: nil, options: .loops)
            try keepAlive.start()
            player.play()
        } catch { stop(); throw SessionFailure.audio }
        feeder = Task.detached { [url] in
            guard let file = try? AVAudioFile(forReading: url), let converter = PCMConverter(from: file.processingFormat) else { return }
            let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            let silence = Data(count: PCMConverter.frameBytes)
            var ended = false
            while !Task.isCancelled {
                if !ended, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                   (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 {
                    for data in converter.frames(from: buffer) { frame(data) }
                } else {
                    ended = true
                    frame(silence); frame(silence)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    func stop() {
        feeder?.cancel(); feeder = nil
        player.stop(); keepAlive.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension LiveNotesController {
    /// The health of a current Mac server with clean-up on this Mac and every notes endpoint.
    static let syntheticHealth = Health(engine: "synthetic", ready: true, correction: "available", correctionLeavesMachine: false,
                                        notesStructure: true, notesCorrection: true, notesReorganize: true, notesContext: true)

    /// UI-test controller: synthetic sockets (ready and a partial on start, a final on stop), a structuring stand-in that
    /// bullets the transcript, quiet synthetic capture and a throwaway encrypted store.
    static func synthetic(coordinator: SessionCoordinator) -> LiveNotesController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-notes-ui-" + UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SyntheticHTTP.self]
        let deps = Dependencies(
            server: { ServerConfig(baseURL: URL(string: "https://synthetic.test.ts.net/chirp")!, token: "synthetic-only") },
            correctionAllowed: { _ in true },
            otherCaptureActive: { [weak coordinator] in coordinator?.armed ?? false },
            http: URLSession(configuration: config),
            fetchHealth: { _, _ in syntheticHealth },
            makeStream: { _, options, _ in StreamSession(transport: SyntheticTransport(automatic: true), options: options) },
            structure: { _, _, request in syntheticStructure(request) },
            reorganize: { _, _, request in syntheticReorganize(request) },
            audio: SyntheticNotesAudio(), requestPermission: { true }, activity: .none,
            store: try? NotesStore(root: root, secrets: MemorySecretStore()))
        return LiveNotesController(deps)
    }

    nonisolated static func syntheticStructure(_ request: NotesStructureRequest) -> NotesStructureResponse {
        let lines = request.transcript.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return NotesStructureResponse(markdown: "## Synthetic notes\n" + lines.map { "- " + $0 }.joined(separator: "\n"), structured: true)
    }

    /// Organize: sorts the bullets (headings first), so a change is visible and Undo can put it back.
    nonisolated static func syntheticReorganize(_ request: NotesReorganizeRequest) -> NotesReorganizeResponse {
        let lines = request.notes.components(separatedBy: "\n").filter { !$0.isEmpty }
        let organized = (lines.filter { !$0.hasPrefix("- ") } + lines.filter { $0.hasPrefix("- ") }.sorted()).joined(separator: "\n")
        return NotesReorganizeResponse(markdown: organized, reorganized: true, changed: organized != request.notes)
    }
}
#endif
