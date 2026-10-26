import Foundation

/// Layout constants for Chirp's top row above the typing keys, kept pure so the iPhone/iPad/landscape rules and the
/// constant height are unit-tested. The keys themselves follow the system keyboard's metrics (KeyboardKit sizes them
/// per device and orientation).
///
/// The keyboard is two rows, as on Android: the top row and the keys. The top row is as tall as the system's predictive
/// bar and shows the word suggestions while idle; in every other state Chirp's controls take over that same row
/// instead of adding one, so the height is the same in every state for a given width and size class.
///
/// Dynamic Type: the row's labels follow the user's text size up to the `maxRowTextPoints` cap (the row is a fixed
/// height), then truncate; every control keeps a full VoiceOver label.
public struct KeyboardMetrics: Equatable, Sendable {
    /// The narrowest the Stop / Open Chirp capsule gets; it stays a full-height touch target.
    public static let minimumPrimaryWidth = 56.0
    /// The ⋯ and ✕ buttons and the idle mic: at least this wide, as tall as the row.
    public static let controlWidth = 44.0
    /// Text-size caps (points) at which Dynamic Type stops growing inside the fixed row.
    public static let maxRowTextPoints = 17.0
    public static let maxChipTextPoints = 17.0
    public static let maxKeyTextPoints = 24.0

    /// The top row (word suggestions, or Chirp's state), as tall as the system's predictive bar.
    public var suggestionHeight: Double
    /// Leading and trailing padding of the row.
    public var inset: Double
    /// The Open Chirp capsule shows its title only where the row has room (iPad); on iPhone it is the label's job.
    public var showsPrimaryTitle: Bool

    /// Chirp's row above the keys. The same for every state.
    public var chromeHeight: Double { suggestionHeight }

    public static func make(width: Double, compactHeight: Bool) -> KeyboardMetrics {
        let wide = width >= 600
        if compactHeight {
            return KeyboardMetrics(suggestionHeight: 36, inset: wide ? 16 : 8, showsPrimaryTitle: wide)
        }
        return wide ? KeyboardMetrics(suggestionHeight: 48, inset: 16, showsPrimaryTitle: true)
                    : KeyboardMetrics(suggestionHeight: 40, inset: 6, showsPrimaryTitle: false)
    }
}
