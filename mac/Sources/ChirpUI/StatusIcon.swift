import ChirpCore

/// How the menu-bar icon looks for a state. Pure, so the rules are tested and the AppKit side only draws.
public struct StatusIcon: Equatable, Sendable {
    public enum Glyph: Sendable { case idle, listening, error }

    public var glyph: Glyph
    /// Dimmed while the server is unreachable.
    public var dimmed: Bool
    /// A small red dot while the server keeps recordings.
    public var debugBadge: Bool
    /// A tiny "cleaned" mark while "Use raw" is on offer after a cleaned insertion.
    public var cleanedBadge: Bool
    /// The sound waves pulse while listening (unless Reduce Motion is on).
    public var animatesWaves: Bool

    public static func of(state: DictationState, serverReachable: Bool, debugRetention: Bool,
                          reduceMotion: Bool = false, rawOfferOpen: Bool = false) -> StatusIcon {
        let glyph: Glyph = switch state {
        case .idle: .idle
        case .connecting, .listening, .finalizing, .correcting, .inserting: .listening
        case .error: .error
        }
        return StatusIcon(glyph: glyph, dimmed: state == .idle && !serverReachable, debugBadge: debugRetention,
                          cleanedBadge: rawOfferOpen && state == .idle, animatesWaves: glyph == .listening && !reduceMotion)
    }

    /// Seconds per wave pulse step.
    public static let pulseInterval = 0.45

    /// Wave opacity at animation step `phase`: alternating bright and faint, steady when Reduce Motion is on.
    public static func waveAlpha(phase: Int, reduceMotion: Bool) -> Double {
        reduceMotion || phase.isMultiple(of: 2) ? 1 : 0.3
    }

    public var accessibilityLabel: String {
        var label = switch glyph {
        case .idle: dimmed ? "Chirp — server unreachable" : "Chirp"
        case .listening: "Chirp — dictating"
        case .error: "Chirp — error"
        }
        if cleanedBadge { label += ", cleaned text inserted, Use raw available" }
        if debugBadge { label += ", debug recordings kept" }
        return label
    }
}
