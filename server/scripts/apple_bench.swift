// Compile with: swiftc -parse-as-library -O apple_bench.swift -o /path/outside/repo/apple-bench
// Synthetic fixture input only. Prints metrics and status; never prints recognized text.
import AVFoundation
import Foundation
import Speech

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

@main struct AppleBench {
    static func main() async {
        guard #available(macOS 26, *) else {
            print("{\"status\":\"unavailable_os\"}")
            return
        }
        do {
            guard SpeechTranscriber.isAvailable else {
                print("{\"status\":\"speech_transcriber_unavailable\"}")
                return
            }
            let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                                preset: .progressiveTranscription)
            let status = await AssetInventory.status(forModules: [transcriber])
            if status != .installed {
                print("{\"status\":\"english_assets_missing_operator_model_install_required\"}")
                return
            }
            guard CommandLine.arguments.count > 1 else {
                print("{\"status\":\"ready\"}")
                return
            }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let file = try AVAudioFile(forReading: url)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let loaded = CFAbsoluteTimeGetCurrent()
            try await analyzer.prepareToAnalyze(in: file.processingFormat)
            let warm = (CFAbsoluteTimeGetCurrent() - loaded) * 1000
            let start = CFAbsoluteTimeGetCurrent()
            let receiver = Task { () throws -> (String, Double?, Int) in
                var text = "", first: Double? = nil, count = 0
                for try await result in transcriber.results {
                    if !result.text.characters.isEmpty && first == nil {
                        first = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    }
                    count += 1
                    if result.isFinal { text += String(result.text.characters) }
                }
                return (text, first, count)
            }
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let (text, first, count) = try await receiver.value
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
                url.deletingLastPathComponent().appendingPathComponent("manifest.json"))) as! [[String: Any]]
            let reference = manifest.first { ($0["file"] as? String) == url.lastPathComponent }?["reference"] as? String ?? ""
            let result: [String: Any] = [
                "status": "ok", "engine": "Apple SpeechAnalyzer", "audio_seconds": seconds,
                "prepare_ms": warm, "decode_ms": elapsed, "rtfx": seconds * 1000 / elapsed,
                "first_result_ms": first as Any? ?? NSNull(), "result_count": count,
                "characters": text.count, "wer": wordErrorRate(reference, text), "peak_rss_mib": Double(usage.ru_maxrss) / 1048576,
                "mode": "file (not real-time streaming)"
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            // Error descriptions may contain paths/transcripts. Emit the safe domain/code only.
            let issue = error as NSError
            print("{\"status\":\"failed\",\"domain\":\"\(issue.domain)\",\"code\":\(issue.code)}")
        }
    }
}
