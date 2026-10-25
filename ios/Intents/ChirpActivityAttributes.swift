import ActivityKit
import Foundation

/// Deliberately content-free: never add text, URLs, hostnames, prompts or tokens.
struct ChirpActivityAttributes: ActivityAttributes, Sendable {
    enum Phase: String, Codable, Hashable, Sendable {
        case armed, connecting, listening, correcting, finished, failed

        init(coordinatorPhase: String) {
            self = Self(rawValue: coordinatorPhase) ?? .armed
        }

        /// The short phase name, the same vocabulary as the keyboard's status strip.
        var headline: String {
            switch self {
            case .armed: "Ready"
            case .connecting: "Connecting…"
            case .listening: "Listening…"
            case .correcting: "Polishing…"
            case .finished: "Finished"
            case .failed: "Needs attention"
            }
        }

        /// The full status, always saying the microphone is active (and read by VoiceOver).
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

    struct ContentState: Codable, Hashable, Sendable {
        var phase: Phase
        var debugRetention: Bool
        /// When the current utterance started, so the system counts the time by itself. Nil outside connecting/listening.
        var listeningSince: Date? = nil
    }
}
