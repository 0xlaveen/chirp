#if os(macOS)
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

    // MARK: custom shortcuts

    private static let customPrefix = "custom:"

    /// A recorded shortcut. Not validated here: `HotKeyValidation.validate` decides which combinations can fire.
    public static func custom(keyCode: UInt32, modifiers: UInt32) -> KeyCombo {
        KeyCombo(id: "\(customPrefix)\(keyCode):\(modifiers)",
                 title: HotKeyValidation.modifierSymbols(modifiers) + KeyNames.name(for: keyCode),
                 keyCode: keyCode, modifiers: modifiers)
    }

    public var isCustom: Bool { id.hasPrefix(Self.customPrefix) }

    /// The stored id back to a combo: a preset, or a custom shortcut that still passes validation. Anything else
    /// (unknown ids, a custom id that can never fire, such as one saved by hand) falls back to the default.
    public static func resolve(id: String?) -> KeyCombo {
        guard let id, id.hasPrefix(customPrefix) else { return preset(id: id) }
        let parts = id.dropFirst(customPrefix.count).split(separator: ":")
        guard parts.count == 2, let key = UInt32(parts[0]), let mods = UInt32(parts[1]),
              case .success(let combo) = HotKeyValidation.validate(keyCode: key, modifiers: mods) else { return .controlOptionSpace }
        return combo
    }
}

/// Which recorded shortcuts can actually fire, and why not when they cannot. Carbon registers some combinations
/// without error that never reach the app, so registration success proves nothing.
public enum HotKeyValidation {
    public enum Rejection: Error, Equatable, Sendable {
        case noModifier
        case shiftOnly
        /// Since macOS 15 a Carbon hot key whose only modifiers are ⌥ or ⌥⇧ is registered and never delivered.
        case optionOnly
        /// ⌃Space alone: Raycast's default shortcut and the input-source switcher.
        case controlSpace
        case reserved(String)
        case escape

        /// One sentence for the recorder to show next to the field.
        public var reason: String {
            switch self {
            case .noModifier: "Hold ⌃ or ⌘ together with the key."
            case .shiftOnly: "⇧ alone would break typing. Add ⌃ or ⌘."
            case .optionOnly: "macOS 15 and later never delivers shortcuts that use only ⌥ or ⌥⇧. Add ⌃ or ⌘."
            case .controlSpace: "⌃Space is Raycast’s default shortcut and the input-source switcher. Try ⌃⌥Space."
            case .reserved(let owner): "macOS reserves this shortcut for \(owner)."
            case .escape: "Esc cancels a dictation, so it can’t start one."
            }
        }
    }

    public static let relevantModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    private static let reserved: [(key: Int, modifiers: Int, owner: String)] = [
        (kVK_Space, cmdKey, "Spotlight"),
        (kVK_Space, controlKey | cmdKey, "Emoji & Symbols"),
        (kVK_Tab, cmdKey, "the app switcher"),
        (kVK_Tab, cmdKey | shiftKey, "the app switcher"),
        (kVK_ANSI_Q, cmdKey, "Quit"),
    ]

    /// `modifiers` are Carbon flags; bits other than ⌃⌥⇧⌘ (caps lock, fn) are ignored.
    public static func validate(keyCode: UInt32, modifiers rawModifiers: UInt32) -> Result<KeyCombo, Rejection> {
        let modifiers = rawModifiers & relevantModifiers
        if Int(keyCode) == kVK_Escape { return .failure(.escape) }
        if modifiers == 0 { return .failure(.noModifier) }
        if modifiers == UInt32(shiftKey) { return .failure(.shiftOnly) }
        if modifiers == UInt32(optionKey) || modifiers == UInt32(optionKey | shiftKey) { return .failure(.optionOnly) }
        if Int(keyCode) == kVK_Space, modifiers == UInt32(controlKey) { return .failure(.controlSpace) }
        if let hit = reserved.first(where: { $0.key == Int(keyCode) && UInt32($0.modifiers) == modifiers }) {
            return .failure(.reserved(hit.owner))
        }
        return .success(.custom(keyCode: keyCode, modifiers: modifiers))
    }

    /// ⌃⌥⇧⌘ in the order macOS writes them.
    public static func modifierSymbols(_ modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }
}

/// Display names for virtual key codes (ANSI layout; the shortcut is stored as a key code, not a character).
public enum KeyNames {
    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_ForwardDelete: "⌦",
        kVK_Escape: "Esc", kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    public static func name(for keyCode: UInt32) -> String { names[Int(keyCode)] ?? "Key \(keyCode)" }
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

#endif
