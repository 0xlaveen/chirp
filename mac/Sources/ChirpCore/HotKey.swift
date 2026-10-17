import Carbon.HIToolbox
import Foundation

/// A global shortcut: a Carbon key code plus Carbon modifier flags (`optionKey`, `controlKey`, …).
public struct KeyCombo: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let keyCode: UInt32
    public let modifiers: UInt32

    public static let controlOptionSpace = KeyCombo(id: "control-option-space", title: "⌃⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
    public static let controlShiftSpace = KeyCombo(id: "control-shift-space", title: "⌃⇧Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey))
    public static let controlOptionCommandSpace = KeyCombo(id: "control-option-command-space", title: "⌃⌥⌘Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey | cmdKey))
    public static let escape = KeyCombo(id: "escape", title: "Esc", keyCode: UInt32(kVK_Escape), modifiers: 0)

    /// Selectable dictation hotkeys; the first is the default. Each includes ⌃ or ⌘: since macOS 15, Carbon hot keys
    /// whose only modifiers are ⌥ (or ⌥⇧) register without error but never fire. ⌃Space alone is Raycast's default
    /// and the system input-source switcher, so it is not offered.
    public static let presets: [KeyCombo] = [.controlOptionSpace, .controlShiftSpace, .controlOptionCommandSpace]

    /// Unknown ids, including the retired "option-space" and "option-shift-space", fall back to the default.
    public static func preset(id: String?) -> KeyCombo { presets.first { $0.id == id } ?? .controlOptionSpace }
}

/// Registers Carbon hot keys, which deliver press *and* release without Input Monitoring permission.
/// Carbon delivers these on the main thread through the application event target.
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    private struct Entry {
        var ref: EventHotKeyRef?
        var onDown: () -> Void
        var onUp: () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var handlerInstalled = false
    private static let signature: OSType = 0x43484B50   // 'CHKP'

    private init() {}

    /// Registers `combo` under `id`, replacing an earlier registration with the same id.
    @discardableResult
    public func register(id: UInt32, combo: KeyCombo, onDown: @escaping () -> Void, onUp: @escaping () -> Void = {}) -> Bool {
        installHandlerIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        chirpLog.info("hotkey register id=\(id, privacy: .public) combo=\(combo.id, privacy: .public) status=\(status, privacy: .public)")
        guard status == noErr else { return false }
        entries[id] = Entry(ref: ref, onDown: onDown, onUp: onUp)
        return true
    }

    public func unregister(id: UInt32) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if let ref = entry.ref { UnregisterEventHotKey(ref) }
    }

    /// Routes a Carbon event to its handlers (also called directly by tests).
    func dispatch(id: UInt32, pressed: Bool) {
        guard let entry = entries[id] else { return }
        if pressed { entry.onDown() } else { entry.onUp() }
    }

    /// Test hook: add handlers without touching Carbon.
    func addForTesting(id: UInt32, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        entries[id] = Entry(ref: nil, onDown: onDown, onUp: onUp)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            chirpLog.info("hotkey event id=\(hotKeyID.id, privacy: .public) pressed=\(pressed, privacy: .public)")
            MainActor.assumeIsolated { HotKeyCenter.shared.dispatch(id: hotKeyID.id, pressed: pressed) }
            return noErr
        }, types.count, &types, nil, nil)
    }
}
