import ChirpCore

/// How the menu-bar icon looks for a state. Pure, so the rules are tested and the AppKit side only draws.
public struct StatusIcon: Equatable, Sendable {
    public enum Glyph: Sendable { case idle, listening, error }

    public var glyph: Glyph
    /// Dimmed while the server is unreachable or Chirp is paused.
    public var dimmed: Bool
    /// The menu's switch is off.
    public var paused = false
    /// A small red dot while the server keeps recordings.
    public var debugBadge: Bool
    /// A tiny "cleaned" mark while "Use raw" is on offer after a cleaned insertion.
    public var cleanedBadge: Bool
    /// The sound waves pulse while listening (unless Reduce Motion is on).
    public var animatesWaves: Bool
    /// Live Notes holds the microphone open: the listening glyph, so an open mic is never invisible.
    public var notes = false

    public static func of(state: DictationState, serverReachable: Bool, debugRetention: Bool,
                          reduceMotion: Bool = false, rawOfferOpen: Bool = false, paused: Bool = false,
                          notesRecording: Bool = false) -> StatusIcon {
        // Paused never has a dictation under way (pausing ends it), so the idle bird is dimmed.
        if paused {
            return StatusIcon(glyph: .idle, dimmed: true, paused: true, debugBadge: debugRetention, cleanedBadge: false, animatesWaves: false)
        }
        if notesRecording {
            return StatusIcon(glyph: .listening, dimmed: false, debugBadge: debugRetention, cleanedBadge: false,
                              animatesWaves: !reduceMotion, notes: true)
        }
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
        case .idle: paused ? "Chirp — paused" : dimmed ? "Chirp — server unreachable" : "Chirp"
        case .listening: notes ? "Chirp — taking notes" : "Chirp — dictating"
        case .error: "Chirp — error"
        }
        if cleanedBadge { label += ", cleaned text inserted, Use raw available" }
        if debugBadge { label += ", debug recordings kept" }
        return label
    }
}
