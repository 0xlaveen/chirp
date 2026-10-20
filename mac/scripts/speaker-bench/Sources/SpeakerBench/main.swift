// Feeds a 16 kHz mono PCM16 WAV through the real Live Notes path, as the microphone would: 50 ms frames into
// `NotesRecorder.handleFrame`, the real `NotesSegmenter` cuts, rolling `/v1/stream` sockets to a local chirp-server
// (word timings on), and one `SortformerSpeakerDiarizer` for the document. Writes one JSON per clip: the labelled
// segments, the diarizer's spans, label lags and costs. `score.py` scores it against the reference.
//
// usage: SpeakerBench --server URL --token FILE --out DIR [--precision fp16|palettized] [--speed X]
//                     [--restart-at S --gap S] clip.wav...
import ChirpCore
import ChirpSpeakers
import Darwin
import Foundation

struct Options {
    var server = URL(string: "http://127.0.0.1:7911")!
    var token: String?
    var out = URL(fileURLWithPath: ".")
    var precision = SpeakerModel.precision
    var variant = SpeakerModel.Variant.fast
    /// Feed speed relative to real time (1 = live).
    var speed = 1.0
    /// Stop at this document second, wait `gap` seconds, and Record again into the same document.
    var restartAt: Double?
    var gap = 10.0
    var clips: [URL] = []

    init(_ args: [String]) {
        var i = 0
        func next() -> String { i += 1; return args[i] }
        while i < args.count {
            switch args[i] {
            case "--server": server = URL(string: next())!
            case "--token": token = try? String(contentsOfFile: next(), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            case "--out": out = URL(fileURLWithPath: next())
            case "--precision": precision = SpeakerModel.Precision(rawValue: next())!
            case "--variant": variant = SpeakerModel.Variant(rawValue: next())!
            case "--speed": speed = Double(next())!
            case "--restart-at": restartAt = Double(next())!
            case "--gap": gap = Double(next())!
            default: clips.append(URL(fileURLWithPath: args[i]))
            }
            i += 1
        }
    }
}

struct TurnOut: Codable { var person: Int; var start: Double; var raw: String; var text: String; var approximate: Bool }
struct SegmentOut: Codable {
    var offset: Double; var raw: String; var text: String; var gap: String?; var tentative: Bool; var turns: [TurnOut]?
}
struct SpanOut: Codable { var spk: String; var start: Double; var end: Double }
struct ClipOut: Codable {
    var clip: String
    var precision: String
    var speed: Double
    var audioSeconds: Double
    var wallSeconds: Double
    var cpuSeconds: Double
    var diarizerSeconds: Double
    var diarizerAudioSeconds: Double
    var droppedFrames: Int
    var errors: Int
    var rssBeforeMiB: Double
    /// Resident memory after the model loaded, at the end of the session, and the process peak (the load included).
    var rssLoadedMiB: Double
    var rssEndMiB: Double
    var rssPeakMiB: Double
    var modelLoadSeconds: Double
    var lags: [Double]
    var tentative: Int
    var speakers: Int
    var segments: [SegmentOut]
    var spans: [SpanOut]
}

func pcm(_ url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    var i = 12
    while i + 8 <= data.count {
        let id = String(decoding: data[i..<(i + 4)], as: UTF8.self)
        let size = Int(data[i + 4]) | Int(data[i + 5]) << 8 | Int(data[i + 6]) << 16 | Int(data[i + 7]) << 24
        if id == "data" { return data.subdata(in: (i + 8)..<min(i + 8 + size, data.count)) }
        i += 8 + size + (size & 1)
    }
    throw CocoaError(.fileReadCorruptFile)
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

/// Resident memory now and the peak, MiB.
func rss() -> (now: Double, peak: Double) {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return (ok == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0, Double(u.ru_maxrss) / 1_048_576)
}

@MainActor
func waitFor(_ what: String, timeout: Double = 30, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw NSError(domain: "bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out: \(what)"]) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
func run(_ clip: URL, _ o: Options, model: LoadedSpeakerModel, loadSeconds: Double, rssBefore: Double,
         rssLoaded: Double) async throws -> ClipOut {
    let audio = try pcm(clip)
    let config = ServerConfig(baseURL: o.server, token: o.token)
    let recorder = NotesRecorder(makeSession: { StreamSession(config: config, options: $0) },
                                 structure: { _ in .failed("off") },
                                 options: StartOptions(client: "mac", correction: false, wordTimings: true),
                                 structuring: false, health: nil, serverHost: o.server.host ?? "")
    let diarizer = model.makeDiarizer()
    recorder.speakers = diarizer
    var lags: [Double] = []
    var tentative = 0
    recorder.onLabels = { lag, t in lags.append(lag); if t { tentative += 1 } }
    let cpu0 = cpuSeconds(), wall0 = Date()
    recorder.start()
    try await waitFor("ready") { recorder.state == .recording }
    let frame = 1600
    var restarted = false
    var clock = ContinuousClock.now
    var i = 0
    while i < audio.count {
        let chunk = audio.subdata(in: i..<min(i + frame, audio.count))
        recorder.handleFrame(chunk, level: Level(pcm16: chunk))
        i += chunk.count
        clock = clock.advanced(by: .seconds(0.05 / o.speed))
        try await Task.sleep(until: clock, clock: .continuous)
        if let at = o.restartAt, !restarted, Double(i) / 32_000 >= at {
            restarted = true
            await recorder.stop()
            try await Task.sleep(for: .seconds(o.gap))
            recorder.start()
            try await waitFor("ready again") { recorder.state == .recording }
            clock = .now
        }
    }
    await recorder.stop()
    let wall = Date().timeIntervalSince(wall0), cpu = cpuSeconds() - cpu0
    let d = recorder.document
    let segments = d.segments.map { s in
        SegmentOut(offset: s.offset, raw: s.raw, text: s.text, gap: s.failure, tentative: s.labelsTentative,
                   turns: s.turns?.map { TurnOut(person: d.roster.resolve($0.person), start: $0.start, raw: $0.raw, text: $0.text,
                                                 approximate: $0.approximate) })
    }
    let timeline = diarizer.snapshot
    let spans = (timeline.spans + timeline.tentative).map { SpanOut(spk: "S\($0.slot)", start: $0.start, end: $0.end) }
    let stats = diarizer.stats
    return ClipOut(clip: clip.deletingPathExtension().lastPathComponent, precision: o.precision.rawValue, speed: o.speed,
                   audioSeconds: Double(audio.count) / 32_000, wallSeconds: wall, cpuSeconds: cpu,
                   diarizerSeconds: stats.processSeconds, diarizerAudioSeconds: stats.audioSeconds,
                   droppedFrames: stats.droppedFrames, errors: stats.errors, rssBeforeMiB: rssBefore, rssLoadedMiB: rssLoaded,
                   rssEndMiB: rss().now, rssPeakMiB: rss().peak,
                   modelLoadSeconds: loadSeconds, lags: lags, tentative: tentative, speakers: d.speakerCount,
                   segments: segments, spans: spans)
}

@MainActor
func main() async throws {
    let o = Options(Array(CommandLine.arguments.dropFirst()))
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    let rssBefore = rss().now
    let t0 = Date()
    let model = try await SpeakerModel.load(o.precision, variant: o.variant)
    let loadSeconds = Date().timeIntervalSince(t0)
    let rssLoaded = rss().now
    for clip in o.clips {
        let result = try await run(clip, o, model: model, loadSeconds: loadSeconds, rssBefore: rssBefore, rssLoaded: rssLoaded)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let suffix = (o.variant == .fast ? "" : ".\(o.variant.rawValue)") + (o.restartAt == nil ? "" : ".restart")
        try enc.encode(result).write(to: o.out.appendingPathComponent("\(result.clip).\(o.precision.rawValue)\(suffix).json"))
        let p95 = result.lags.sorted().dropFirst(Int(Double(result.lags.count) * 0.95)).first ?? 0
        FileHandle.standardError.write(Data(String(format: "%@ %@: %.0f s audio in %.0f s, diarizer %.1f s (%.1f%%), cpu %.1f s, %d speakers, lag p95 %.2f s, rss %.0f MiB\n",
            result.clip, result.precision, result.audioSeconds, result.wallSeconds, result.diarizerSeconds,
            100 * result.diarizerSeconds / result.audioSeconds, result.cpuSeconds, result.speakers, p95, result.rssPeakMiB).utf8))
    }
}

try await main()
