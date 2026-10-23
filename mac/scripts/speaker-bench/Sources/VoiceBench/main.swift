// Voice-profile bench (issue #18 M3, docs/bench.md "Voice profiles"). Feeds each two-voice conversation from
// make_voice_clips.py through the app's own `SortformerSpeakerDiarizer` with the app's `WeSpeakerEmbedder` attached,
// as Live Notes does, and reads each diarizer slot's session voiceprint after 45 s and at the end. Each voice is
// remembered from its first conversation (as "Remember this voice" would), then every other conversation is a test:
// with 4 of the remembered voices saved and every other voice unknown (one rotation per remembered voice), the app's `VoiceMatch.suggest` either suggests the right
// name, nothing, or a wrong one. Prints true- and false-suggestion rates over a threshold × margin sweep.
//
// usage: VoiceBench --clips DIR [--out FILE.json]
import ChirpCore
import ChirpSpeakers
import Foundation

let voices = ["Samantha", "Daniel", "Moira", "Rishi", "Karen", "Aman", "Tessa", "Tara"]
/// Seconds into a conversation for the early reading (each voice has spoken ~20 s by then).
let checkpoint = 45.0

var clips = URL(fileURLWithPath: ".")
var outFile: URL?
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--clips": clips = URL(fileURLWithPath: args.next()!)
    case "--out": outFile = URL(fileURLWithPath: args.next()!)
    default: fatalError("unknown argument \(a)")
    }
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

/// RTTM speaker index → voice name, and its turns.
func reference(_ url: URL, voices pair: [String]) throws -> [(voice: String, start: Double, end: Double)] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
        let f = line.split(separator: " ")
        guard f.count > 7, let start = Double(f[3]), let dur = Double(f[4]), let idx = Int(f[7].dropFirst(3)) else { return nil }
        return (pair[idx], start, start + dur)
    }
}

/// One conversation's voiceprints by true voice (the slot mapped to the voice it overlaps most), at a checkpoint.
typealias Heard = [String: Voiceprint]

func label(_ prints: [Int: Voiceprint], spans: [SpeakerSpan], truth: [(voice: String, start: Double, end: Double)]) -> Heard {
    var out: Heard = [:]
    for (slot, print) in prints {
        var overlap: [String: Double] = [:]
        for s in spans where s.slot == slot {
            for t in truth { overlap[t.voice, default: 0] += max(0, min(s.end, t.end) - max(s.start, t.start)) }
        }
        guard let voice = overlap.max(by: { $0.value < $1.value })?.key else { continue }
        out[voice, default: Voiceprint()].add(print)
    }
    return out
}

@MainActor
func run() async throws {
    let model = try await SpeakerModel.load(download: false)
    let embedder = try await VoiceModel.load(download: true)
    var sessions: [(name: String, pair: [String], early: Heard, end: Heard)] = []
    for (i, a) in voices.enumerated() {
        for b in voices[(i + 1)...] {
            let name = "pair_\(a)_\(b)"
            let audio = try pcm(clips.appendingPathComponent(name + ".wav"))
            let truth = try reference(clips.appendingPathComponent(name + ".rttm"), voices: [a, b])
            let diarizer = model.makeSortformerDiarizer()
            diarizer.attachEmbedder(embedder)
            let frame = 1600 * 2
            var early: Heard = [:]
            var at = 0
            while at < audio.count {
                let chunk = audio.subdata(in: at..<min(at + frame, audio.count))
                diarizer.feed(chunk, at: Double(at / 2) / 16_000)
                at += chunk.count
                // Faster than live, but never so far ahead that the diarizer's 30 s queue drops audio.
                while Double(at / 2) / 16_000 - diarizer.stats.audioSeconds > 10 { try await Task.sleep(for: .milliseconds(5)) }
                if early.isEmpty, at / 2 >= Int(checkpoint) * 16_000 {
                    // Let the model catch up, then read what Live Notes would know this far in.
                    while diarizer.stats.audioSeconds + 0.6 < checkpoint { try await Task.sleep(for: .milliseconds(5)) }
                    early = label(diarizer.voiceprints, spans: diarizer.snapshot.spans, truth: truth)
                }
            }
            await diarizer.flush()
            let end = label(diarizer.voiceprints, spans: diarizer.snapshot.spans, truth: truth)
            sessions.append((name, [a, b], early, end))
            let secs = end.map { "\($0.key)=\(Int($0.value.seconds))s" }.sorted().joined(separator: " ")
            FileHandle.standardError.write(Data("\(name): \(secs)\n".utf8))
        }
    }

    // Each voice's profile: its voiceprint from the first conversation it is in.
    var profiles: [String: VoiceProfile] = [:]
    var enrolledFrom: [String: String] = [:]
    for s in sessions {
        for v in s.pair where profiles[v] == nil {
            guard let print = s.end[v], print.seconds >= VoiceMatch.enrolSeconds else { continue }
            profiles[v] = VoiceProfile(name: v, embedding: print.centroid, model: VoiceModel.id, seconds: print.seconds)
            enrolledFrom[v] = s.name
        }
    }

    struct Rates: Codable { var trials = 0, known = 0, right = 0, wrong = 0, unknownSuggested = 0, unknown = 0 }
    var table: [String: [String: Rates]] = [:]
    let remembered = voices.filter { profiles[$0] != nil }
    print("remembered: \(remembered.joined(separator: ", ")) (others never reached \(Int(VoiceMatch.enrolSeconds)) s in one conversation)")
    for checkpoint in ["45s", "end"] {
        for threshold in stride(from: Float(0.5), through: 0.86, by: 0.05) {
            for margin in [Float(0.05), 0.10, 0.15] {
                var r = Rates()
                for rotation in remembered.indices {
                    let saved = Set((0..<4).map { remembered[(rotation + $0) % remembered.count] })
                    let usable = saved.compactMap { profiles[$0] }
                    for s in sessions {
                        let heard = checkpoint == "45s" ? s.early : s.end
                        // People are numbered here only to call the app's matcher; a person = one true voice.
                        let people = Dictionary(uniqueKeysWithValues: s.pair.enumerated().compactMap { i, v in heard[v].map { (i + 1, $0) } })
                        let suggested = VoiceMatch.suggest(people, profiles: usable, model: VoiceModel.id,
                                                           threshold: threshold, margin: margin)
                        for (i, v) in s.pair.enumerated() {
                            guard let p = people[i + 1], p.seconds >= VoiceMatch.minSeconds, enrolledFrom[v] != s.name else { continue }
                            r.trials += 1
                            let name = suggested[i + 1].flatMap { id in usable.first { $0.id == id }?.name }
                            if saved.contains(v) {
                                r.known += 1
                                if name == v { r.right += 1 } else if name != nil { r.wrong += 1 }
                            } else {
                                r.unknown += 1
                                if name != nil { r.unknownSuggested += 1; r.wrong += 1 }
                            }
                        }
                    }
                }
                table[checkpoint, default: [:]][String(format: "t%.2f_m%.2f", threshold, margin)] = r
                print(String(format: "%@ τ=%.2f margin=%.2f  true %.1f%% (%d/%d)  false %.2f%% (%d/%d; unknown voices named %d/%d)",
                             checkpoint, threshold, margin, 100 * Double(r.right) / Double(max(r.known, 1)), r.right, r.known,
                             100 * Double(r.wrong) / Double(max(r.trials, 1)), r.wrong, r.trials, r.unknownSuggested, r.unknown))
            }
        }
    }
    if let outFile { try JSONEncoder().encode(table).write(to: outFile) }
}

try await run()
