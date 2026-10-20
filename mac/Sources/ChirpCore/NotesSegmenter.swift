import Foundation

/// Decides where a Live Notes recording is cut into segments, each one an ordinary utterance well under the server's
/// 120 s cap. It prefers a pause: never before `minSegment`, then at the first `pauseCut` of quiet (a shorter
/// `relaxedPause` once the segment is past `relaxedAfter`), and at `maxSegment` whatever is being said.
/// Fed once per 50 ms frame from the capture thread, under the sink's lock, like `SilenceGuard`.
public struct NotesSegmenter: Sendable {
    public static let minSegment: TimeInterval = 20
    public static let pauseCut: TimeInterval = 0.6
    public static let relaxedAfter: TimeInterval = 60
    public static let relaxedPause: TimeInterval = 0.3
    public static let maxSegment: TimeInterval = 90
    /// A frame is quiet below this RMS (0…1).
    public static let quietRMS: Float = 0.015

    /// Audio in the current segment, seconds.
    public private(set) var elapsed: TimeInterval = 0
    /// Trailing quiet in the current segment, seconds.
    public private(set) var quiet: TimeInterval = 0

    public init() {}

    /// Adds one frame; true means cut now (after this frame). The caller cuts and then calls `reset()`.
    public mutating func feed(_ level: Level, duration: TimeInterval) -> Bool {
        elapsed += duration
        quiet = level.rms < Self.quietRMS ? quiet + duration : 0
        // A little slack so 50 ms frames that sum to 89.99999 s still cut "at 90 s".
        let epsilon = 1e-6
        if elapsed + epsilon >= Self.maxSegment { return true }
        guard elapsed + epsilon >= Self.minSegment else { return false }
        let pause = elapsed + epsilon >= Self.relaxedAfter ? Self.relaxedPause : Self.pauseCut
        return quiet + epsilon >= pause
    }

    public mutating func reset() {
        elapsed = 0
        quiet = 0
    }
}
