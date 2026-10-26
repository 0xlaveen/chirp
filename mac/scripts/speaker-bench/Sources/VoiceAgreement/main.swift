// The `wespeaker_v2` agreement spike (issue #247, docs/bench.md "Saved voices (server)"): embeds every 16 kHz PCM16
// WAV in a folder with the Mac's own `WeSpeakerEmbedder` (FluidAudio's `wespeaker_v2` CoreML at `df2625ac`, the model
// the Mac's Keychain voices were saved with), so `server/scripts/bench_voices.py` can compare each clip with the
// server's WeSpeaker ResNet34-LM ONNX embedding of the same audio. Offline: the model must already be downloaded.
//
// usage: VoiceAgreement --clips DIR --out FILE.json
import ChirpCore
import ChirpSpeakers
import Foundation

var clips = URL(fileURLWithPath: ".")
var outFile = URL(fileURLWithPath: "mac-embeddings.json")
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--clips": clips = URL(fileURLWithPath: args.next()!)
    case "--out": outFile = URL(fileURLWithPath: args.next()!)
    default: fatalError("unknown argument \(a)")
    }
}

func samples(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    var i = 12
    while i + 8 <= data.count {
        let id = String(decoding: data[i..<(i + 4)], as: UTF8.self)
        let size = Int(data[i + 4]) | Int(data[i + 5]) << 8 | Int(data[i + 6]) << 16 | Int(data[i + 7]) << 24
        if id == "data" {
            let body = data.subdata(in: (i + 8)..<min(i + 8 + size, data.count))
            return body.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
        }
        i += 8 + size + (size & 1)
    }
    throw CocoaError(.fileReadCorruptFile)
}

let embedder = try await VoiceModel.load(download: false)
var out: [String: [Float]] = [:]
let names = try FileManager.default.contentsOfDirectory(atPath: clips.path).filter { $0.hasSuffix(".wav") }.sorted()
for name in names {
    out[name] = try embedder.embedding(samples(clips.appendingPathComponent(name)))
}
try JSONEncoder().encode(out).write(to: outFile)
print("embedded \(out.count) clips with \(VoiceModel.id)")
