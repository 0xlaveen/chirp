// Metrics-only FluidAudio v0.17.7 candidate. Built against an external cached source tree.
import FluidAudio
import Foundation
import AVFoundation

func wordErrorRate(_ reference: String, _ hypothesis: String) -> Double {
    func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .split(separator: " ").map(String.init)
    }
    let a = words(reference), b = words(hypothesis)
    var row = Array(0...b.count)
    for (i, word) in a.enumerated() {
        var next = [i + 1] + Array(repeating: 0, count: b.count)
        for (j, other) in b.enumerated() {
            next[j + 1] = min(row[j + 1] + 1, next[j] + 1, row[j] + (word == other ? 0 : 1))
        }
        row = next
    }
    return Double(row[b.count]) / Double(max(a.count, 1))
}

@main struct FluidBench {
    static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
                root.appendingPathComponent("manifest.json"))) as! [[String: Any]]
            let started = CFAbsoluteTimeGetCurrent()
            guard CommandLine.arguments.contains("--download-models") else {
                print("{\"status\":\"explicit_download_flag_required\"}")
                return
            }
            let modelDirectory = root.deletingLastPathComponent().appendingPathComponent("FluidModels")
            let models = try await AsrModels.downloadAndLoad(to: modelDirectory, version: .v2)
            let load = CFAbsoluteTimeGetCurrent() - started
            let manager = AsrManager(models: models)
            var clips: [[String: Any]] = []
            for entry in manifest {
                let path = root.appendingPathComponent(entry["file"] as! String)
                var times: [Double] = [], lastText = "", duration = 0.0
                for iteration in 0..<4 {
                    var state = TdtDecoderState.make(decoderLayers: 2)
                    let start = CFAbsoluteTimeGetCurrent()
                    let result = try await manager.transcribe(path, decoderState: &state)
                    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    if iteration > 0 { times.append(elapsed) }
                    lastText = result.text
                    duration = result.duration
                }
                let median = times.sorted()[1]
                clips.append(["audio_seconds": duration, "decode_ms": median,
                              "rtfx": duration * 1000 / median,
                              "wer": wordErrorRate(entry["reference"] as! String, lastText)])
            }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let result: [String: Any] = ["engine": "FluidAudio 0.17.7 v2 int8 ANE",
                "acquire_and_load_seconds": load, "clips": clips,
                "peak_rss_mib": Double(usage.ru_maxrss) / 1048576,
                "mode": "batch file; streaming not measured"]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result,
                  options: [.sortedKeys]), as: UTF8.self))
        } catch {
            let issue = error as NSError
            print("{\"status\":\"failed\",\"domain\":\"\(issue.domain)\",\"code\":\(issue.code)}")
        }
    }
}
