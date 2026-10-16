import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The real implementations behind `InsertionEnvironment`.
@MainActor
public enum SystemInsertion {
    public static func environment() -> InsertionEnvironment {
        InsertionEnvironment(
            secureInputEnabled: { IsSecureEventInputEnabled() },
            axTrusted: { AXIsProcessTrusted() },
            frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            axInsert: { await axInsert($0) },
            postPaste: { postCommandKey(CGKeyCode(kVK_ANSI_V)) }
        )
    }

    // MARK: AX

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success ? ref : nil
    }

    private static func range(_ element: AXUIElement) -> CFRange? {
        guard let v = copy(element, "AXSelectedTextRange"), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    /// Sets `AXSelectedText` on the focused element and checks that the value or caret actually moved.
    static func axInsert(_ text: String) async -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        guard let focused = copy(system, "AXFocusedUIElement"), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return false
        }
        let element = focused as! AXUIElement
        if let role = copy(element, "AXRole") as? String, role == "AXSecureTextField" { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, "AXSelectedText" as CFString, &settable) == .success,
              settable.boolValue else { return false }

        let beforeValue = copy(element, "AXValue") as? String
        let beforeRange = range(element)
        // If we can't read the field back we can't verify the write, so let paste handle it.
        guard beforeValue != nil || beforeRange != nil else { return false }

        guard AXUIElementSetAttributeValue(element, "AXSelectedText" as CFString, text as CFString) == .success else {
            return false
        }
        try? await Task.sleep(for: .milliseconds(40))
        let afterValue = copy(element, "AXValue") as? String
        let afterRange = range(element)
        if let beforeValue, let afterValue, beforeValue != afterValue { return true }
        if let b = beforeRange, let a = afterRange, b.location != a.location || b.length != a.length { return true }
        return false
    }

    // MARK: Keystroke

    /// Posts ⌘+key using a private event source so a still-held hotkey modifier (⌥) is not merged in.
    static func postCommandKey(_ key: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// ⌘Z, used by "Use raw" to take back an inserted correction.
    public static func postUndo() -> Bool { postCommandKey(CGKeyCode(kVK_ANSI_Z)) }
}
