import Foundation

/// Layout constants, kept pure so the iPhone/iPad/landscape rules and the constant height are unit-tested.
///
/// The keyboard is four rows: the 44 pt status strip, the primary control, the chip row and the typing row.
/// Every row always reserves its height (chips that don't apply are hidden, never removed), so the total is the
/// same in every state for a given width and size class.
///
/// Dynamic Type: the strip, chip and primary labels follow the user's text size up to AX3 (the `maxTextPoints` caps,
/// which are what AX3 resolves to for those text styles), then truncate; every control keeps a full VoiceOver label.
/// A keyboard extension has a fixed height budget, so the rows never grow with the text size.
public struct KeyboardMetrics: Equatable, Sendable {
    public static let minimumPrimaryHeight = 64.0
    /// The status strip is one line, 44 pt, in every state and size.
    public static let stripHeight = 44.0
    /// The primary control and iPad column cap (iPhone fills the width).
    public static let iPadColumnWidth = 440.0
    /// Text-size caps (points) at which Dynamic Type stops growing inside the fixed rows (≈ AX3).
    public static let maxStripTextPoints = 22.0
    public static let maxChipTextPoints = 19.0
    public static let maxPrimaryTextPoints = 28.0
    public static let maxKeyTextPoints = 24.0

    public var stripHeight: Double
    public var primaryHeight: Double
    public var chipHeight: Double
    public var keyHeight: Double
    public var spacing: Double
    public var inset: Double
    /// Top and bottom padding around the four rows.
    public var verticalInset: Double
    /// `nil` = full width (iPhone); iPad caps the strip, primary and chips at one readable column and centers it.
    public var maxPrimaryWidth: Double?

    /// The whole keyboard: four rows, three gaps and the vertical padding. The same for every state.
    public var totalHeight: Double {
        stripHeight + primaryHeight + chipHeight + keyHeight + spacing * 3 + verticalInset * 2
    }

    public static func make(width: Double, compactHeight: Bool) -> KeyboardMetrics {
        let wide = width >= 600
        if compactHeight {
            return KeyboardMetrics(stripHeight: stripHeight, primaryHeight: 64, chipHeight: 36, keyHeight: 36, spacing: 6,
                                   inset: wide ? 24 : 10, verticalInset: 4, maxPrimaryWidth: wide ? iPadColumnWidth : nil)
        }
        return wide ? KeyboardMetrics(stripHeight: stripHeight, primaryHeight: 76, chipHeight: 44, keyHeight: 56, spacing: 12,
                                      inset: 24, verticalInset: 8, maxPrimaryWidth: iPadColumnWidth)
                    : KeyboardMetrics(stripHeight: stripHeight, primaryHeight: 64, chipHeight: 40, keyHeight: 48, spacing: 8,
                                      inset: 10, verticalInset: 6, maxPrimaryWidth: nil)
    }
}
