import Foundation

/// Whether Chirp Keyboard presses Return after a finished dictation (Android #89 / #101). Off by default.
/// A custom keyboard can only type Return; the host decides what it does. Where the field's Return key is an
/// action (Send, Go, Done…) that action runs; in a plain field it is a newline. A keyboard cannot see which app it
/// is in, so Android's "chat apps only" mode has no iOS equivalent.
public enum AutoEnterMode: String, Sendable, CaseIterable {
    case off
    /// Only where the field's Return key is Send, Go, Done, Join, Route or Continue.
    case actionKeys
    /// Also in plain fields, where Return is a newline.
    case always

    public var title: String {
        switch self {
        case .off: "Off"
        case .actionKeys: "On Send, Go or Done keys"
        case .always: "Always"
        }
    }
}

/// The field's Return key, mirrored from `UIReturnKeyType` (this package has no UIKit dependency).
public enum ReturnKey: Sendable, Equatable {
    case plain, send, go, done, join, route, `continue`, search, next, other
}

public enum AutoEnter {
    public static let sent = "↵ sent"

    /// Press Return after this final? Never after a kept (partial) result, a cursor move, blank text or an
    /// earlier long-dictation segment. Search and Next are left alone: they search early or move focus.
    public static func presses(mode: AutoEnterMode, returnKey: ReturnKey, kept: Bool, moved: Bool,
                               lastSegment: Bool, text: String) -> Bool {
        guard mode != .off, !kept, !moved, lastSegment,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch returnKey {
        case .send, .go, .done, .join, .route, .continue: return true
        case .search, .next: return false
        case .plain, .other: return mode == .always
        }
    }
}
