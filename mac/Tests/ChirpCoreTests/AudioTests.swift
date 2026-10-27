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

    @Test(arguments: [16_000.0, 48_000.0])
    func repeatedFramesAndPartialTailMatchUnframedConversion(rate: Double) throws {
        let framed = try #require(PCMConverter(from: sine(rate: rate, channels: 2, seconds: 0.064).format))
        let unframed = try #require(PCMConverter(from: sine(rate: rate, channels: 2, seconds: 0.064).format))
        var expected = Data(), actual = Data()
        var sawSlicedFrame = false
        for i in 0..<7 {
            let buffer = sine(rate: rate, channels: 2, seconds: 0.064, amplitude: Float(i + 1) / 10)
            expected.append(unframed.convert(buffer))
            for frame in framed.frames(from: buffer) {
                #expect(frame.count == PCMConverter.frameBytes)
                sawSlicedFrame = sawSlicedFrame || frame.startIndex > 0
                actual.append(frame)
            }
        }
        let tail = try #require(framed.flush())
        #expect(tail.count > 0 && tail.count < PCMConverter.frameBytes)
        actual.append(tail)
        if let delay = unframed.flush() { expected.append(delay) }
        #expect(sawSlicedFrame)
        #expect(actual == expected)
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

    @Test func levelMatchesAPerSampleLoopExactly() {
        var rng = SystemRandomNumberGenerator()
        for count in [1, 3, 800, 801, 16_000] {
            var samples = (0..<count).map { _ in Int16.random(in: .min ... .max, using: &rng) }
            samples[0] = .min
            let data = samples.withUnsafeBytes { Data($0) }
            var peak: Int32 = 0, sum = 0.0
            for v in samples.map(Int32.init) { peak = max(peak, abs(v)); sum += Double(v) * Double(v) }
            let expected = Level(peak: Float(peak) / 32768, rms: Float((sum / Double(count)).squareRoot() / 32768))
            #expect(Level(pcm16: data) == expected)
            #expect(Level(pcm16: data + Data([7])) == expected)   // a stray odd byte is ignored
        }
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
