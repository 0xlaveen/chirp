import Foundation

/// Layout constants for Chirp's rows above the typing keys, kept pure so the iPhone/iPad/landscape rules and the
/// constant height are unit-tested. The keys themselves follow the system keyboard's metrics (KeyboardKit sizes them
/// per device and orientation).
///
/// The keyboard is three rows: the 44 pt Chirp strip, the suggestion row and the keys. Chirp's action chips take
/// over the suggestion row instead of adding one, so the height is the same in every state for a given width and
/// size class.
///
/// Dynamic Type: the strip and chip labels follow the user's text size up to AX3 (the `maxTextPoints` caps, which
/// are what AX3 resolves to for those text styles), then truncate; every control keeps a full VoiceOver label. A
/// keyboard extension has a fixed height budget, so the rows never grow with the text size.
public struct KeyboardMetrics: Equatable, Sendable {
    /// The status strip is one line, 44 pt (the minimum touch target), in every state and size.
    public static let stripHeight = 44.0
    /// The narrowest the strip's mic/Stop capsule gets; it stays a 44 pt target.
    public static let minimumPrimaryWidth = 56.0
    /// Text-size caps (points) at which Dynamic Type stops growing inside the fixed rows (≈ AX3).
    public static let maxStripTextPoints = 22.0
    public static let maxChipTextPoints = 19.0
    public static let maxPrimaryTextPoints = 22.0
    public static let maxKeyTextPoints = 24.0

    public var stripHeight: Double
    /// The suggestion row (word suggestions or Chirp's chips), as tall as the system's predictive bar.
    public var suggestionHeight: Double
    /// Leading and trailing padding of the strip and the chips.
    public var inset: Double
    /// The mic/Stop capsule shows its title ("Start dictation") only where the strip has room (iPad).
    public var showsPrimaryTitle: Bool
    /// The remaining-session time in the idle strip; narrow strips leave it to ⓘ.
    public var showsRemaining: Bool

    /// Chirp's rows above the keys. The same for every state.
    public var chromeHeight: Double { stripHeight + suggestionHeight }

    public static func make(width: Double, compactHeight: Bool) -> KeyboardMetrics {
        let wide = width >= 600
        if compactHeight {
            return KeyboardMetrics(stripHeight: stripHeight, suggestionHeight: 36, inset: wide ? 16 : 8,
                                   showsPrimaryTitle: wide, showsRemaining: true)
        }
        return wide ? KeyboardMetrics(stripHeight: stripHeight, suggestionHeight: 48, inset: 16,
                                      showsPrimaryTitle: true, showsRemaining: true)
                    : KeyboardMetrics(stripHeight: stripHeight, suggestionHeight: 40, inset: 6,
                                      showsPrimaryTitle: false, showsRemaining: width >= 390)
    }
}
