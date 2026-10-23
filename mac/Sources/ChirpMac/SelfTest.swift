import AVFoundation
import ChirpCore
import Foundation

/// `ChirpMac --selftest <wav> [--url URL] [--token-file PATH] [--correction] [--profile ID] [--fast] [--expect word]…`
/// Streams a WAV through the real protocol without the mic and prints partials, the final and timings.
/// The transcript goes to stdout because the operator asked for it; nothing is written to disk.
enum SelfTest {
    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        guard let path = value("--selftest") else { return usage() }
        let fast = args.contains("--fast")
        let expects = args.enumerated().filter { $0.element == "--expect" }.compactMap { args.indices.contains($0.offset + 1) ? args[$0.offset + 1] : nil }

        var config = ServerConfig.load(urlString: value("--url") ?? settings.serverURL,
                                       tokenPath: value("--token-file") ?? ServerConfig.defaultTokenPath)
        if let t = ProcessInfo.processInfo.environment["CHIRP_TOKEN"] { config.token = t }

        let frames: [Data]
        do { frames = try loadFrames(path) } catch {
            print("selftest: cannot read \(path): \(error.localizedDescription)")
            return 2
        }
        let audioMs = frames.count * 50
        print("selftest: \(path) → \(config.streamURL.absoluteString) (\(audioMs) ms audio, \(fast ? "fast" : "real-time"))")

        let session = StreamSession(config: config, options: StartOptions(client: "mac", correction: args.contains("--correction"),
                                                                  correctionProfile: value("--profile") ?? CorrectionProfile.defaultID))
        let t0 = ContinuousClock.now
        func ms(_ since: ContinuousClock.Instant = t0) -> Int {
            let d = ContinuousClock.now - since
            return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        }

        let reader = Task { () -> (FinalResult?, String?) in
            for await event in session.events {
                switch event {
                case .message(.ready(let id, let engine, let debug)):
                    print("  +\(ms())ms ready session=\(id) engine=\(engine ?? "?")\(debug ? "  ** DEBUG RETENTION ON **" : "")")
                case .message(.partial(let seq, let text, let stable, _)):
                    print("  +\(ms())ms partial #\(seq) stable=\(stable.count)ch: \(text)")
                case .message(.correcting(let seq, _, let profile, _)):
                    print("  +\(ms())ms correcting #\(seq) profile=\(profile)")
                case .message(.final(let f)): return (f, nil)
                case .message(.error(let code, let message)): return (nil, "\(code): \(message)")
                case .message(.unknown): break
                case .closed(let reason): return (nil, reason ?? "closed")
                }
            }
            return (nil, "stream ended")
        }

        await session.open()
        // Pace against absolute deadlines so per-frame sleep overshoot on a loaded host does not
        // stretch the stream beyond real time.
        let paceStart = ContinuousClock.now
        for (i, frame) in frames.enumerated() {
            session.sendAudio(frame)
            if !fast { try? await Task.sleep(until: paceStart + .milliseconds(50 * (i + 1)), clock: .continuous) }
        }
        let stopAt = ContinuousClock.now
        await session.stop()

        let outcome = await withTaskGroup(of: (FinalResult?, String?).self) { group in
            group.addTask { await reader.value }
            group.addTask { try? await Task.sleep(for: .seconds(60)); return (nil, "timed out waiting for final") }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        await session.close()

        guard let final = outcome.0 else {
            print("selftest: FAILED — \(outcome.1 ?? "no final")")
            return 1
        }
        print("final: \(final.text)")
        if final.corrected { print("raw:   \(final.raw)  (corrected=true)") }
        if let e = final.correctionError { print("correction_error: \(e)") }
        let t = final.timings
        print("timings: stop→final \(ms(stopAt)) ms (client)  server audio=\(fmt(t?.audio)) first_partial=\(fmt(t?.firstPartial)) finalize=\(fmt(t?.finalize)) correction=\(fmt(t?.correction))")

        let lower = final.text.lowercased()
        let missing = expects.filter { !lower.contains($0.lowercased()) }
        if !missing.isEmpty { print("selftest: FAILED — missing expected words: \(missing.joined(separator: ", "))"); return 3 }
        if final.text.trimmingCharacters(in: .whitespaces).isEmpty { print("selftest: FAILED — empty final"); return 4 }
        print("selftest: OK")
        return 0
    }

    private static func fmt(_ v: Double?) -> String { v.map { String(Int($0)) + "ms" } ?? "n/a" }

    private static func usage() -> Int32 {
        print("usage: ChirpMac --selftest <file.wav> [--url URL] [--token-file PATH] [--correction] [--profile ID] [--fast] [--expect WORD]…")
        return 64
    }

    /// Any audio file AVFoundation reads → 16 kHz mono PCM16, cut into 50 ms frames.
    static func loadFrames(_ path: String) throws -> [Data] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CaptureError.converter
        }
        try file.read(into: buffer)
        guard let converter = PCMConverter(from: file.processingFormat) else { throw CaptureError.converter }
        var frames = converter.frames(from: buffer)
        if var tail = converter.flush() {
            if tail.count < PCMConverter.frameBytes { tail.append(Data(count: PCMConverter.frameBytes - tail.count)) }
            frames.append(tail)
        }
        return frames
    }
}
