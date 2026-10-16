import Foundation

public enum InsertionMethod: String, Sendable, Equatable {
    case ax, paste, copy
}

public enum InsertionOutcome: Sendable, Equatable {
    case inserted(InsertionMethod)
    case copied
    case refusedSecure
}

/// Chooses which insertion methods to try, in order. Pure, so it is unit-tested.
public enum InsertionPolicy {
    /// Apps where setting the AX selected text is unreliable or meaningless, so we go straight to paste.
    /// Terminals have no AX text field; Electron/Chromium editors often accept the AX write without showing it.
    public static let pasteFirstBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", // VS Code, Cursor
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "notion.id",
    ]

    public enum Plan: Sendable, Equatable {
        case refuseSecure
        case try_([InsertionMethod])
    }

    public static func plan(secureInput: Bool, axTrusted: Bool, bundleID: String?) -> Plan {
        if secureInput { return .refuseSecure }
        // Without Accessibility trust we can neither set AX text nor post ⌘V.
        if !axTrusted { return .try_([.copy]) }
        if let bundleID, pasteFirstBundleIDs.contains(bundleID) { return .try_([.paste, .copy]) }
        return .try_([.ax, .paste, .copy])
    }
}
