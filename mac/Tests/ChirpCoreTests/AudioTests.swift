import AVFoundation
import Testing
@testable import ChirpCore

@Suite struct AudioTests {
    private func sine(rate: Double, channels: AVAudioChannelCount, seconds: Double, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let n = AVAudioFrameCount(rate * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buf.frameLength = n
        for c in 0..<Int(channels) {
            for i in 0..<Int(n) { buf.floatChannelData![c][i] = amplitude * sinf(2 * .pi * 440 * Float(i) / Float(rate)) }
        }
        return buf
    }

    @Test func convertsStereo48kToFramedMono16k() throws {
        let buf = sine(rate: 48_000, channels: 2, seconds: 1)
        let conv = try #require(PCMConverter(from: buf.format))
        let frames = conv.frames(from: buf)
        #expect(frames.allSatisfy { $0.count == PCMConverter.frameBytes })
        let total = frames.count * PCMConverter.frameBytes + (conv.flush()?.count ?? 0)
        // 1 s at 16 kHz mono PCM16 = 32000 bytes; flush() must drain the resampler so the tail is not lost.
        #expect(abs(total - 32_000) < 200, "total=\(total) frames=\(frames.count)")
        let level = Level(pcm16: frames[5])
        #expect(level.peak > 0.3 && level.peak < 0.7)
    }

    @Test func accumulatesAcrossSmallBuffers() throws {
        let tiny = sine(rate: 16_000, channels: 1, seconds: 0.02)   // 640 bytes: below one frame
        let conv = try #require(PCMConverter(from: tiny.format))
        #expect(conv.frames(from: tiny).isEmpty)
        #expect(conv.frames(from: tiny).isEmpty)
        #expect(conv.frames(from: tiny).count == 1)                  // 1920 bytes → one 1600-byte frame
    }

    @Test func rejectsInvalidInputFormat() {
        let bad = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false)
        #expect(bad == nil || PCMConverter(from: bad!) == nil)
    }

    @Test func levelOfSilenceAndFullScale() {
        #expect(Level(pcm16: Data(count: 3200)) == .zero)
        var loud = Data()
        for _ in 0..<100 { withUnsafeBytes(of: Int16.max.littleEndian) { loud.append(contentsOf: $0) } }
        #expect(Level(pcm16: loud).peak > 0.99)
        #expect(Level(pcm16: Data()) == .zero)
    }

    @Test func silenceGuardFiresOnceAfterWindow() {
        var g = SilenceGuard(window: 1.5)
        var fired: [Double] = []
        for i in 0..<60 where g.feed(.zero, at: Double(i) * 0.05) { fired.append(Double(i) * 0.05) }
        #expect(fired.count == 1)
        #expect(abs(fired[0] - 1.5) < 0.06)
    }

    @Test func silenceGuardResetsOnSignal() {
        var g = SilenceGuard(window: 1.5)
        var t = 0.0
        var fired = false
        for _ in 0..<20 { fired = g.feed(.zero, at: t) || fired; t += 0.05 }    // 1 s of silence
        fired = g.feed(Level(peak: 0.01, rms: 0.01), at: t) || fired; t += 0.05  // a sample of signal resets
        for _ in 0..<20 { fired = g.feed(.zero, at: t) || fired; t += 0.05 }
        #expect(!fired)
    }
}
