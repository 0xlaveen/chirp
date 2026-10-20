import Foundation

/// Keyboard-local elapsed timer: starts when this keyboard first observes connecting/listening for
/// an utterance it owns, and clears as soon as that stops being true. Nothing here crosses the bridge.
public struct RecordingClock: Equatable, Sendable {
    public private(set) var startedAt: Date?
    private var utteranceID: UUID?
    public init() {}

    public mutating func observe(phase: KeyboardPhase?, ownedUtterance: UUID?, now: Date) {
        guard let ownedUtterance, phase == .connecting || phase == .listening else {
            startedAt = nil; utteranceID = nil; return
        }
        if startedAt == nil || utteranceID != ownedUtterance { startedAt = now; utteranceID = ownedUtterance }
    }

    public func elapsed(now: Date) -> TimeInterval? { startedAt.map { max(0, now.timeIntervalSince($0)) } }
}

public enum ClockText {
    /// `m:ss`, or `h:mm:ss` from one hour. Negative and non-finite input shows zero.
    public static func format(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Press-and-hold repeat for Delete: a pause, then an accelerating cadence.
public enum KeyRepeat {
    public static let initialDelay: TimeInterval = 0.4
    public static func interval(afterRepeats count: Int) -> TimeInterval { count < 4 ? 0.12 : count < 12 ? 0.07 : 0.035 }
}
