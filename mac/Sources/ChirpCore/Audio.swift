import AVFoundation
import Foundation

/// Converts capture buffers to 16 kHz mono PCM16LE and cuts them into fixed-size frames.
public final class PCMConverter {
    public static let sampleRate: Double = 16_000
    /// 50 ms at 16 kHz mono PCM16 (the protocol allows 20–100 ms).
    public static let frameBytes = 1_600

    private let converter: AVAudioConverter
    private let outFormat: AVAudioFormat
    private var pending = Data()

    public init?(from input: AVAudioFormat) {
        guard input.sampleRate > 0, input.channelCount > 0,
              let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
                                      channels: 1, interleaved: true),
              let c = AVAudioConverter(from: input, to: out) else { return nil }
        outFormat = out
        converter = c
    }

    /// Converts one buffer and returns every complete frame; the remainder waits for the next call.
    public func frames(from buffer: AVAudioPCMBuffer) -> [Data] {
        append(convert(buffer))
    }

    /// Whatever is left (shorter than a frame), e.g. at stop. Empty if nothing is pending.
    public func flush() -> Data? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : pending
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data {
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return Data() }
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let ptr = out.int16ChannelData?[0] else { return Data() }
        return Data(bytes: ptr, count: Int(out.frameLength) * 2)
    }

    private func append(_ data: Data) -> [Data] {
        pending.append(data)
        var frames: [Data] = []
        while pending.count >= Self.frameBytes {
            frames.append(pending.prefix(Self.frameBytes))
            pending.removeFirst(Self.frameBytes)
        }
        return frames
    }
}

public struct Level: Sendable, Equatable {
    public var peak: Float   // 0...1
    public var rms: Float    // 0...1
    public static let zero = Level(peak: 0, rms: 0)

    public init(peak: Float, rms: Float) {
        self.peak = peak
        self.rms = rms
    }

    /// Peak/RMS of little-endian PCM16 mono.
    public init(pcm16 data: Data) {
        var peak: Int32 = 0
        var sum: Double = 0
        let n = data.count / 2
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                let v = Int32(Int16(littleEndian: s[i]))
                peak = max(peak, abs(v))
                sum += Double(v) * Double(v)
            }
        }
        self.peak = Float(peak) / 32768
        self.rms = n == 0 ? 0 : Float((sum / Double(n)).squareRoot() / 32768)
    }
}

/// Fires once when the input has been digitally silent (peak exactly 0) for `window` seconds,
/// which is what a muted device or a denied microphone permission produces.
public struct SilenceGuard: Sendable {
    public let window: TimeInterval
    private var silentSince: TimeInterval?
    private var fired = false

    public init(window: TimeInterval = 1.5) { self.window = window }

    public mutating func feed(_ level: Level, at time: TimeInterval) -> Bool {
        guard !fired else { return false }
        if level.peak > 0 { silentSince = nil; return false }
        let since = silentSince ?? time
        silentSince = since
        if time - since >= window { fired = true; return true }
        return false
    }
}
