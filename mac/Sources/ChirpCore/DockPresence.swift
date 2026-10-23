import Foundation

/// Whether Chirp shows in the Dock and ⌘-Tab (`.regular`) or lives in the menu bar only (`.accessory`). It is regular
/// while a Notes window is on screen (or minimised to the Dock), while Notes records behind a window that was closed
/// to hide it, and always when the user chose "Always show Chirp in the Dock". Closing the last window returns it to
/// the menu bar; a window hidden while nothing records does not hold the Dock icon.
public struct DockPresence: Sendable, Equatable {
    public enum Policy: Sendable, Equatable { case regular, accessory }

    /// Windows on screen or minimised.
    public private(set) var shown = 0
    /// Windows ordered out but not closed (Close while recording only hides).
    public private(set) var hidden = 0
    public private(set) var recording = false
    public var alwaysShow: Bool

    public init(alwaysShow: Bool = false) { self.alwaysShow = alwaysShow }

    public var policy: Policy { alwaysShow || shown > 0 || (recording && hidden > 0) ? .regular : .accessory }

    public mutating func windowShown() {
        if hidden > 0 { hidden -= 1 }
        shown += 1
    }
    /// The window was ordered out but still exists (closing while recording).
    public mutating func windowHidden() {
        guard shown > 0 else { return }
        shown -= 1
        hidden += 1
    }
    /// The window is gone. `wasHidden`: it was hidden, not shown.
    public mutating func windowClosed(wasHidden: Bool = false) {
        if wasHidden { hidden = max(0, hidden - 1) } else { shown = max(0, shown - 1) }
    }
    public mutating func recordingChanged(_ on: Bool) { recording = on }
}
