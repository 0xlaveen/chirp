import ChirpCore
import Foundation

/// Long dictation past the protocol's 120 s cap, as on Android (#76): the microphone hands over to a new
/// utterance at a pause, and earlier segments finish on their own sockets. Segments land oldest first.
enum RollingDictation {
    /// The whole dictation, across segments.
    static let maxTotal: TimeInterval = 600
    /// At most this many earlier segments may still be finalizing; further cuts wait.
    static let maxFinishing = 2
}

/// When to cut: never before 45 s; then at the first 0.6 s of quiet; after 70 s at 0.3 s; always at 90 s.
/// Quiet is a 16 kHz PCM16 frame with RMS below 0.015.
struct DictationSegmenter: Sendable {
    static let minSegment: TimeInterval = 45, pauseCut: TimeInterval = 0.6
    static let relaxedAfter: TimeInterval = 70, relaxedPause: TimeInterval = 0.3
    static let maxSegment: TimeInterval = 90, quietRMS: Float = 0.015
    private(set) var elapsed: TimeInterval = 0
    private(set) var quiet: TimeInterval = 0

    /// Returns true when the segment should end after this frame.
    mutating func feed(rms: Float, duration: TimeInterval) -> Bool {
        elapsed += duration
        quiet = rms < Self.quietRMS ? quiet + duration : 0
        if elapsed + 1e-6 >= Self.maxSegment { return true }
        guard elapsed + 1e-6 >= Self.minSegment else { return false }
        let needed = elapsed + 1e-6 >= Self.relaxedAfter ? Self.relaxedPause : Self.pauseCut
        return quiet + 1e-6 >= needed
    }
    mutating func reset() { elapsed = 0; quiet = 0 }

    /// Root mean square of little-endian PCM16 samples, scaled to 0…1.
    static func rms(pcm16 data: Data) -> Float {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var sum: Double = 0
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
                sum += sample * sample
            }
        }
        return Float((sum / Double(count)).squareRoot())
    }
}

/// An earlier segment of a long dictation: the microphone has moved on and it is finishing on its socket.
@MainActor
final class FinishingSegment {
    enum Outcome { case final(FinalResult), kept(String), nothing }
    let index: Int
    let stream: StreamSession
    var task: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    var partial: String
    var raw = ""
    var lastSequence: Int
    var outcome: Outcome?
    init(index: Int, stream: StreamSession, partial: String, lastSequence: Int, task: Task<Void, Never>?) {
        self.index = index; self.stream = stream; self.partial = partial; self.lastSequence = lastSequence; self.task = task
    }
    /// What a failure keeps: the polishing raw if clean-up had started, else the last partial.
    func fail() {
        guard outcome == nil else { return }
        let heard = raw.isEmpty ? partial : raw
        outcome = heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .nothing : .kept(heard)
    }
    func close() { deadline?.cancel(); task?.cancel(); Task { [stream] in await stream.close() } }
    func cancel() { deadline?.cancel(); task?.cancel(); Task { [stream] in await stream.cancel() } }
}

enum LongText {
    /// The separator before a segment that follows `previous`: a space, unless either side already has one.
    static func joiner(after previous: String, before next: String = "x") -> String {
        guard let last = previous.last, !last.isWhitespace, let first = next.first, !first.isWhitespace else { return "" }
        return " "
    }
    static func join(_ parts: [String]) -> String {
        parts.reduce("") { $0 + joiner(after: $0, before: $1) + $1 }
    }
}
