import ActivityKit
import Foundation

/// Live Notes on the lock screen and in the Dynamic Island. Deliberately content-free: the state and the elapsed time
/// only, never notes, transcript, hosts or tokens.
struct ChirpNotesActivityAttributes: ActivityAttributes, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
        case recording, paused, finishing, offline

        /// The short state beside the record dot: "Recording", "Paused".
        var headline: String {
            switch self {
            case .recording: "Recording"
            case .paused: "Paused"
            case .finishing: "Finishing…"
            case .offline: "Mac offline · audio kept"
            }
        }

        var label: String {
            switch self {
            case .recording: "Live Notes · recording"
            case .paused: "Live Notes · paused"
            case .finishing: "Live Notes · finishing"
            case .offline: "Live Notes · Mac offline, audio kept"
            }
        }
    }

    struct ContentState: Codable, Hashable, Sendable {
        var status: Status
        /// When the elapsed clock read 0:00, so the system can count up by itself while recording.
        var startedAt: Date
        /// Seconds recorded at this update (shown as is while paused or finishing).
        var elapsed: TimeInterval
        var debugRetention: Bool
        /// The note's title, shown instead of the generic label. Optional so older activities still decode.
        var title: String? = nil

        var counting: Bool { status == .recording || status == .offline }

        /// `m:ss` or `h:mm:ss`.
        static func clock(_ seconds: TimeInterval) -> String {
            let s = max(0, Int(seconds))
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        }
    }
}
