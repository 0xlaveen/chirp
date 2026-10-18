import ActivityKit
import Foundation

/// Deliberately content-free: never add text, URLs, hostnames, prompts or tokens.
struct ChirpActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case armed, connecting, listening, correcting, finished, failed

        init(coordinatorPhase: String) {
            self = Self(rawValue: coordinatorPhase) ?? .armed
        }

        var label: String {
            switch self {
            case .armed: "Microphone active · idle audio discarded"
            case .connecting: "Microphone active · connecting"
            case .listening: "Microphone active · dictating"
            case .correcting: "Microphone active · polishing"
            case .finished: "Microphone active · ready"
            case .failed: "Session needs attention"
            }
        }
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        var debugRetention: Bool
    }
}
