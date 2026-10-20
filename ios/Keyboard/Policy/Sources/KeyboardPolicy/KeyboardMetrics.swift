import Foundation

/// Layout constants, kept pure so the iPhone/iPad/landscape rules are unit-tested.
public struct KeyboardMetrics: Equatable, Sendable {
    public static let minimumPrimaryHeight = 64.0
    public var primaryHeight: Double
    public var keyHeight: Double
    public var spacing: Double
    public var inset: Double
    /// `nil` = full width (iPhone); iPad caps the primary button at a readable width and centers it.
    public var maxPrimaryWidth: Double?

    public static func make(width: Double, compactHeight: Bool) -> KeyboardMetrics {
        let wide = width >= 600
        if compactHeight {
            return KeyboardMetrics(primaryHeight: 64, keyHeight: 36, spacing: 6, inset: wide ? 24 : 10,
                                   maxPrimaryWidth: wide ? 440 : nil)
        }
        return wide ? KeyboardMetrics(primaryHeight: 76, keyHeight: 56, spacing: 12, inset: 24, maxPrimaryWidth: 440)
                    : KeyboardMetrics(primaryHeight: 64, keyHeight: 48, spacing: 8, inset: 10, maxPrimaryWidth: nil)
    }
}
