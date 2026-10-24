import AVFoundation
import Foundation

/// Used only on the library's disk actor. Capture callbacks never encode or access the filesystem.
enum NotesAudioEncoder {
    static func write(_ frames: [Data], sampleRate: Double, to url: URL) throws -> Int {
        let pcm = frames.reduce(into: Data()) { $0.append($1) }
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), sampleRate > 0,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
              let output = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: input.frameCapacity),
              let converter = AVAudioConverter(from: inputFormat, to: floatFormat) else { throw CocoaError(.fileWriteUnknown) }
        input.frameLength = input.frameCapacity
        _ = pcm.withUnsafeBytes { source in memcpy(input.int16ChannelData![0], source.baseAddress!, pcm.count) }
        try converter.convert(to: output, from: input)
        try NotesAtomicFile.directory(url.deletingLastPathComponent().deletingLastPathComponent())
        try NotesAtomicFile.directory(url.deletingLastPathComponent())
        let temp = url.deletingPathExtension().appendingPathExtension("tmp.m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        // Pre-create owner-only: AVAudioFile opens this file without exposing an intermediate world-readable file.
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard fchmod(fd, 0o600) == 0 else { close(fd); throw CocoaError(.fileWriteNoPermission) }
        close(fd)
        do {
            let file = try AVAudioFile(forWriting: temp, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: output)
        }
        let syncFD = open(temp.path, O_RDONLY)
        guard syncFD >= 0 else { throw CocoaError(.fileReadUnknown) }
        if fcntl(syncFD, F_FULLFSYNC) != 0 { fsync(syncFD) }
        close(syncFD)
        guard rename(temp.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
