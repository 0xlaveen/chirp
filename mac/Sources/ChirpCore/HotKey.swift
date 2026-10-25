#if os(macOS)
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A global shortcut: a Carbon key code plus Carbon modifier flags (`optionKey`, `controlKey`, …), or a modifier
/// pressed on its own (⌥, Right ⌥, fn…), which `keyCode` marks with `KeyCombo.anyModifierKey` or the modifier key's code.
public struct KeyCombo: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let keyCode: UInt32
    public let modifiers: UInt32

    /// `keyCode` of a modifier-only shortcut that either side's key triggers.
    public static let anyModifierKey: UInt32 = 0xFFFF

    public static let controlOptionSpace = KeyCombo(id: "control-option-space", title: "⌃⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
    public static let controlShiftSpace = KeyCombo(id: "control-shift-space", title: "⌃⇧Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey))
    public static let controlOptionCommandSpace = KeyCombo(id: "control-option-command-space", title: "⌃⌥⌘Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey | cmdKey))
    /// ⌥ on its own, either side. Matched from the event tap, so it needs Accessibility.
    public static let option = KeyCombo(id: "option", title: "⌥ Option", keyCode: anyModifierKey, modifiers: UInt32(optionKey))
    /// The right ⌥ on its own, leaving the left one for typing special characters.
    public static let rightOption = KeyCombo(id: "right-option", title: "Right ⌥ Option", keyCode: UInt32(kVK_RightOption), modifiers: UInt32(optionKey))
    public static let escape = KeyCombo(id: "escape", title: "Esc", keyCode: UInt32(kVK_Escape), modifiers: 0)
    /// Live Notes' fixed toggle (not one of the dictation presets).
    public static let controlOptionN = KeyCombo(id: "control-option-n", title: "⌃⌥N", keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey))
    /// "Open Notes" default: brings the Notes window forward without recording (⌃⌥N records).
    public static let controlOptionShiftN = KeyCombo(id: "control-option-shift-n", title: "⌃⌥⇧N", keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey | shiftKey))

    /// The dictation shortcut for anyone who has not picked one: Right ⌥ on its own, hold to talk or tap to toggle.
    /// ⌃⌥Space was the default before.
    public static let defaultDictation = KeyCombo.rightOption

    /// Selectable dictation hotkeys; the first is the default. ⌃Space alone is Raycast's default and the system
    /// input-source switcher, so it is not offered.
    public static let presets: [KeyCombo] = [.rightOption, .controlOptionSpace, .option, .controlShiftSpace, .controlOptionCommandSpace]

    /// Unknown ids, including the retired "option-space" and "option-shift-space", fall back to the default.
    public static func preset(id: String?) -> KeyCombo { presets.first { $0.id == id } ?? defaultDictation }

    // MARK: custom shortcuts

    private static let customPrefix = "custom:"

    /// A recorded shortcut. Not validated here: `HotKeyValidation.validate` decides which combinations can fire.
    public static func custom(keyCode: UInt32, modifiers: UInt32) -> KeyCombo {
        let title = ModifierKeys.isModifierOnly(keyCode) ? ModifierKeys.title(keyCode: keyCode, modifiers: modifiers)
                                                         : HotKeyValidation.modifierSymbols(modifiers) + KeyNames.name(for: keyCode)
        return KeyCombo(id: "\(customPrefix)\(keyCode):\(modifiers)", title: title, keyCode: keyCode, modifiers: modifiers)
    }

    public var isCustom: Bool { id.hasPrefix(Self.customPrefix) }

    /// A modifier pressed and released on its own, with no other key.
    public var isModifierOnly: Bool { ModifierKeys.isModifierOnly(keyCode) }

    /// A modifier-only shortcut bound to one physical key (Right ⌥, Right ⌘…), not either side's. Pressing the other
    /// side's key never reaches it, so it is safe to start a dictation on a hold (see `HotkeyGesture`).
    public var isSingleModifierKey: Bool { isModifierOnly && keyCode != KeyCombo.anyModifierKey && ModifierKeys.isModifierKey(keyCode) }

    /// Carbon cannot deliver it: a modifier on its own, or a key with only ⌥ (or ⌥⇧), which since macOS 15 registers
    /// without error and never fires. These are matched from a session event tap instead, which needs Accessibility.
    public var needsEventTap: Bool {
        isModifierOnly || modifiers == UInt32(optionKey) || modifiers == UInt32(optionKey | shiftKey)
    }

    /// The stored id back to a combo: a preset, or a custom shortcut that still passes validation. Anything else
    /// (unknown ids, a custom id that can never fire, such as one saved by hand) falls back to the default.
    public static func resolve(id: String?, fallback: KeyCombo = .defaultDictation) -> KeyCombo {
        guard let id else { return fallback }
        if id == fallback.id { return fallback }
        guard id.hasPrefix(customPrefix) else { return presets.first { $0.id == id } ?? fallback }
        let parts = id.dropFirst(customPrefix.count).split(separator: ":")
        guard parts.count == 2, let key = UInt32(parts[0]), let mods = UInt32(parts[1]),
              case .success(let combo) = HotKeyValidation.validate(keyCode: key, modifiers: mods) else { return fallback }
        return combo
    }
}

/// The modifier keys themselves: which Carbon flag each sets, its side, and how a modifier-only shortcut is named.
public enum ModifierKeys {
    /// fn (🌐) as a modifier-only flag; Carbon hot keys have none (this is `kEventKeyModifierFnMask`).
    public static let fn: UInt32 = 1 << 17

    private struct Key {
        let code: Int
        let modifier: Int
        /// The device-dependent `CGEventFlags` bit set while this side's key is down.
        let deviceBit: UInt64
        let side: String?
    }

    private static let keys: [Key] = [
        Key(code: kVK_Control, modifier: controlKey, deviceBit: 0x1, side: "Left"),
        Key(code: kVK_RightControl, modifier: controlKey, deviceBit: 0x2000, side: "Right"),
        Key(code: kVK_Option, modifier: optionKey, deviceBit: 0x20, side: "Left"),
        Key(code: kVK_RightOption, modifier: optionKey, deviceBit: 0x40, side: "Right"),
        Key(code: kVK_Shift, modifier: shiftKey, deviceBit: 0x2, side: "Left"),
        Key(code: kVK_RightShift, modifier: shiftKey, deviceBit: 0x4, side: "Right"),
        Key(code: kVK_Command, modifier: cmdKey, deviceBit: 0x8, side: "Left"),
        Key(code: kVK_RightCommand, modifier: cmdKey, deviceBit: 0x10, side: "Right"),
        Key(code: kVK_Function, modifier: Int(fn), deviceBit: 0x800000, side: nil),
    ]

    /// `CGEventFlags` device-independent masks (shift, control, alternate, command, secondary fn).
    static let cgShift: UInt64 = 0x20000, cgControl: UInt64 = 0x40000, cgOption: UInt64 = 0x80000
    static let cgCommand: UInt64 = 0x100000, cgFn: UInt64 = 0x800000

    public static func isModifierKey(_ keyCode: UInt32) -> Bool { keys.contains { $0.code == Int(keyCode) } }

    /// A modifier-only shortcut's key code: either side, or one modifier key.
    public static func isModifierOnly(_ keyCode: UInt32) -> Bool { keyCode == KeyCombo.anyModifierKey || isModifierKey(keyCode) }

    /// The Carbon flag a modifier key sets.
    public static func modifier(of keyCode: UInt32) -> UInt32? { keys.first { $0.code == Int(keyCode) }.map { UInt32($0.modifier) } }

    /// Whether `keyCode`'s own side is held in `cgFlags` (always true for `anyModifierKey`).
    static func sideHeld(_ keyCode: UInt32, cgFlags: UInt64) -> Bool {
        guard let key = keys.first(where: { $0.code == Int(keyCode) }) else { return true }
        return cgFlags & key.deviceBit != 0
    }

    /// Whether the other side's key of `keyCode`'s modifier is held too (Left ⌥ with Right ⌥); false for fn and for
    /// `anyModifierKey`.
    static func otherSideHeld(_ keyCode: UInt32, cgFlags: UInt64) -> Bool {
        guard let key = keys.first(where: { $0.code == Int(keyCode) }), key.side != nil,
              let other = keys.first(where: { $0.modifier == key.modifier && $0.code != key.code }) else { return false }
        return cgFlags & other.deviceBit != 0
    }

    /// `CGEventFlags` to Carbon flags (⌃⌥⇧⌘, plus `fn` when asked: a key event on a laptop's arrow or F-key carries fn).
    public static func carbon(cgFlags: UInt64, includingFn: Bool) -> UInt32 {
        var m = 0
        if cgFlags & cgControl != 0 { m |= controlKey }
        if cgFlags & cgOption != 0 { m |= optionKey }
        if cgFlags & cgShift != 0 { m |= shiftKey }
        if cgFlags & cgCommand != 0 { m |= cmdKey }
        return UInt32(m) | (includingFn && cgFlags & cgFn != 0 ? fn : 0)
    }

    /// A modifier-only title such as "⌥ Option" or "Right ⌥ Option": one keycap, not a glyph and a word.
    public static func isNamedTitle(_ title: String) -> Bool {
        ["Control", "Option", "Shift", "Command"].contains { title.hasSuffix(" \($0)") }
    }

    /// "⌥ Option", "Right ⌥ Option", "fn", or the symbols when several modifiers make up the shortcut ("⌃⌥").
    static func title(keyCode: UInt32, modifiers: UInt32) -> String {
        let symbols = HotKeyValidation.modifierSymbols(modifiers)
        let names: [UInt32: String] = [UInt32(controlKey): "Control", UInt32(optionKey): "Option", UInt32(shiftKey): "Shift",
                                       UInt32(cmdKey): "Command"]
        guard let name = names[modifiers] else { return symbols }
        let side = keys.first { $0.code == Int(keyCode) }?.side.map { "\($0) " } ?? ""
        return "\(side)\(symbols) \(name)"
    }
}

/// Which recorded shortcuts can actually fire, and why not when they cannot. Carbon registers some combinations
/// without error that never reach the app, so registration success proves nothing; those go through the event tap.
public enum HotKeyValidation {
    public enum Rejection: Error, Equatable, Sendable {
        /// A typing key on its own would stop that key from typing.
        case noModifier
        case shiftOnly
        /// ⇧ on its own is pressed for every capital letter.
        case shiftAlone
        /// ⌃Space alone: Raycast's default shortcut and the input-source switcher.
        case controlSpace
        case reserved(String)
        case escape
        /// Another Chirp shortcut already uses it ("Dictation", "Start/stop Notes").
        case inUse(String)

        /// One sentence for the recorder to show next to the field.
        public var reason: String {
            switch self {
            case .noModifier: "On its own this key would stop typing. Add ⌃, ⌥ or ⌘, or press a modifier alone."
            case .shiftOnly: "⇧ alone would break typing. Add ⌃, ⌥ or ⌘."
            case .shiftAlone: "⇧ on its own is pressed for every capital letter. Try ⌥ or Right ⌥."
            case .controlSpace: "⌃Space is Raycast’s default shortcut and the input-source switcher. Try ⌃⌥Space."
            case .reserved(let owner): "macOS reserves this shortcut for \(owner)."
            case .escape: "Esc cancels a dictation, so it can’t start one."
            case .inUse(let owner): "Already used for \(owner). Pick another."
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

    /// `modifiers` are Carbon flags; bits other than ⌃⌥⇧⌘ (caps lock; fn unless the shortcut is a modifier alone)
    /// are ignored. A modifier key's own code, or `KeyCombo.anyModifierKey`, makes a modifier-only shortcut.
    public static func validate(keyCode: UInt32, modifiers rawModifiers: UInt32) -> Result<KeyCombo, Rejection> {
        if Int(keyCode) == kVK_Escape { return .failure(.escape) }
        if ModifierKeys.isModifierOnly(keyCode) {
            var modifiers = rawModifiers & (relevantModifiers | ModifierKeys.fn)
            if let own = ModifierKeys.modifier(of: keyCode) {
                // One side's key: the shortcut is that modifier alone.
                modifiers = own
            }
            if modifiers == 0 { return .failure(.noModifier) }
            if modifiers == UInt32(shiftKey) { return .failure(.shiftAlone) }
            return .success(combo(keyCode: keyCode, modifiers: modifiers))
        }
        let modifiers = rawModifiers & relevantModifiers
        let typing = KeyNames.isTypingKey(keyCode)
        if modifiers == 0, typing { return .failure(.noModifier) }
        if modifiers == UInt32(shiftKey), typing { return .failure(.shiftOnly) }
        if Int(keyCode) == kVK_Space, modifiers == UInt32(controlKey) { return .failure(.controlSpace) }
        if let hit = reserved.first(where: { $0.key == Int(keyCode) && UInt32($0.modifiers) == modifiers }) {
            return .failure(.reserved(hit.owner))
        }
        return .success(combo(keyCode: keyCode, modifiers: modifiers))
    }

    /// Whether `combo` is already another Chirp shortcut: `taken` lists the others by what they do. A modifier alone
    /// (⌥) also clashes with a shortcut made of that modifier, so only the same keys count here.
    public static func conflict(_ combo: KeyCombo, with taken: [(owner: String, combo: KeyCombo)]) -> Rejection? {
        taken.first { $0.combo.keyCode == combo.keyCode && $0.combo.modifiers == combo.modifiers }.map { .inUse($0.owner) }
    }

    /// The preset with these keys when there is one (recording ⌥ alone gives the "⌥ Option" preset), else a custom one.
    private static func combo(keyCode: UInt32, modifiers: UInt32) -> KeyCombo {
        KeyCombo.presets.first { $0.keyCode == keyCode && $0.modifiers == modifiers } ?? .custom(keyCode: keyCode, modifiers: modifiers)
    }

    /// fn⌃⌥⇧⌘ in the order macOS writes them.
    public static func modifierSymbols(_ modifiers: UInt32) -> String {
        var s = ""
        if modifiers & ModifierKeys.fn != 0 { s += "fn" }
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

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13,
        kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// Every key but F1–F20 types or moves the cursor, so on its own (or with ⇧ alone) it cannot be the shortcut.
    public static func isTypingKey(_ keyCode: UInt32) -> Bool { !functionKeys.contains(Int(keyCode)) }
}

/// Matches one shortcut against the raw key events of the session event tap, for what Carbon cannot deliver.
/// A key shortcut is pressed and released like a Carbon hot key, and its events are swallowed so the focused app never
/// types them. A modifier-only shortcut is never swallowed (the modifier keeps working for everything else): it is
/// down while exactly its modifiers are held, and pressing any other key or modifier meanwhile makes it a `chord` —
/// the user meant ⌥← or ⌥-click, not dictation — and nothing more fires until its modifiers are let go.
public struct ShortcutMatcher: Sendable {
    public enum Action: Sendable, Equatable { case down, up, chord }
    public struct Outcome: Sendable, Equatable {
        public var action: Action?
        /// Keep the event from the focused app.
        public var swallow = false
        static let none = Outcome(action: nil)
    }

    private enum Phase: Sendable { case idle, pressed, spoiled }

    public let combo: KeyCombo
    private var phase = Phase.idle

    public init(combo: KeyCombo) { self.combo = combo }

    public mutating func keyDown(keyCode: UInt16, cgFlags: UInt64, isRepeat: Bool) -> Outcome {
        if combo.isModifierOnly {
            guard phase == .pressed else { return .none }
            phase = .spoiled
            return Outcome(action: .chord)
        }
        guard UInt32(keyCode) == combo.keyCode else { return .none }
        if phase == .pressed { return Outcome(action: nil, swallow: true) }   // key repeat
        guard ModifierKeys.carbon(cgFlags: cgFlags, includingFn: false) == combo.modifiers else { return .none }
        if isRepeat { return Outcome(action: nil, swallow: true) }
        phase = .pressed
        return Outcome(action: .down, swallow: true)
    }

    public mutating func keyUp(keyCode: UInt16) -> Outcome {
        guard !combo.isModifierOnly, phase == .pressed, UInt32(keyCode) == combo.keyCode else { return .none }
        phase = .idle
        return Outcome(action: .up, swallow: true)
    }

    /// A modifier went down or up; `keyCode` is the modifier key that changed.
    public mutating func flagsChanged(keyCode: UInt16, cgFlags: UInt64) -> Outcome {
        guard combo.isModifierOnly else { return .none }
        let mods = ModifierKeys.carbon(cgFlags: cgFlags, includingFn: true)
        let side = ModifierKeys.sideHeld(combo.keyCode, cgFlags: cgFlags)
        let holdsAll = mods & combo.modifiers == combo.modifiers && side
        // Right ⌥ with Left ⌥ already held is not Right ⌥ alone: the left one is typing é or a shortcut.
        let exact = mods == combo.modifiers && side && !ModifierKeys.otherSideHeld(combo.keyCode, cgFlags: cgFlags)
        switch phase {
        case .idle:
            // Only pressing one of its own modifiers starts it: letting go of ⌘ in ⌘⌥ leaves ⌥ held, but that is not a press.
            let pressedOwn = (ModifierKeys.modifier(of: UInt32(keyCode)) ?? 0) & combo.modifiers != 0
            if exact, pressedOwn {
                phase = .pressed
                return Outcome(action: .down)
            }
            // Its modifier held together with another one (⌘ then ⌥): wait until they are let go.
            if mods & combo.modifiers != 0, mods & ~combo.modifiers != 0 { phase = .spoiled }
            if holdsAll, !exact { phase = .spoiled }
        case .pressed:
            if exact { return .none }
            if holdsAll {
                phase = .spoiled   // another modifier joined
                return Outcome(action: .chord)
            }
            phase = .idle
            return Outcome(action: .up)
        case .spoiled:
            if mods & combo.modifiers == 0 || !side { phase = .idle }
        }
        return .none
    }

    /// The tap was off and may have missed events: catch up with the modifiers held now (`cgFlags`). A press it saw
    /// ends if they were let go meanwhile; a press it missed does not start.
    public mutating func resync(cgFlags: UInt64) -> Outcome {
        guard combo.isModifierOnly, phase != .idle else { return .none }
        return flagsChanged(keyCode: UInt16(truncatingIfNeeded: KeyCombo.anyModifierKey), cgFlags: cgFlags)
    }

    /// A click while the modifier is held (⌥-click) is a chord too.
    public mutating func mouseDown() -> Outcome {
        guard combo.isModifierOnly, phase == .pressed else { return .none }
        phase = .spoiled
        return Outcome(action: .chord)
    }
}

/// Registers global shortcuts. Carbon hot keys deliver press *and* release without Input Monitoring permission, on
/// the main thread through the application event target. Shortcuts Carbon cannot deliver (`KeyCombo.needsEventTap`)
/// come from a session event tap on the main run loop instead, which exists only while one is registered and needs
/// Accessibility (registration fails without it).
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    private struct Entry {
        var combo: KeyCombo?
        var ref: EventHotKeyRef?
        var onDown: () -> Void
        var onUp: () -> Void
    }

    private struct TapEntry {
        var matcher: ShortcutMatcher
        var onDown: () -> Void
        var onUp: () -> Void
        var onChord: () -> Void
    }

    /// One event from the tap, reduced to what the matchers need.
    enum TapEvent: Sendable {
        case keyDown(keyCode: UInt16, cgFlags: UInt64, isRepeat: Bool)
        case keyUp(keyCode: UInt16)
        case flagsChanged(keyCode: UInt16, cgFlags: UInt64)
        case mouseDown
        /// The tap was turned back on; `cgFlags` are the modifiers held now.
        case resync(cgFlags: UInt64)
    }

    private var entries: [UInt32: Entry] = [:]
    private var tapEntries: [UInt32: TapEntry] = [:]
    private var handlerInstalled = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Handlers matched by the tap, run on the next main-queue turn.
    private var pendingHandlers: [() -> Void] = []
    private static let signature: OSType = 0x43484B50   // 'CHKP'

    private init() {}

    /// Registers `combo` under `id`, replacing an earlier registration with the same id. The same shortcut again keeps
    /// its registration (and a press under way) and only takes the new handlers. `onChord` fires when a modifier-only
    /// shortcut turned out to be part of another shortcut (see `ShortcutMatcher`).
    @discardableResult
    public func register(id: UInt32, combo: KeyCombo, onDown: @escaping () -> Void, onUp: @escaping () -> Void = {},
                         onChord: @escaping () -> Void = {}) -> Bool {
        if tapEntries[id]?.matcher.combo == combo {
            tapEntries[id]?.onDown = onDown
            tapEntries[id]?.onUp = onUp
            tapEntries[id]?.onChord = onChord
            return true
        }
        if entries[id]?.combo == combo {
            entries[id]?.onDown = onDown
            entries[id]?.onUp = onUp
            return true
        }
        unregister(id: id)
        if combo.needsEventTap {
            let running = startTap()
            chirpLog.info("hotkey register id=\(id, privacy: .public) combo=\(combo.id, privacy: .public) tap=\(running, privacy: .public)")
            guard running else { return false }
            tapEntries[id] = TapEntry(matcher: ShortcutMatcher(combo: combo), onDown: onDown, onUp: onUp, onChord: onChord)
            return true
        }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        chirpLog.info("hotkey register id=\(id, privacy: .public) combo=\(combo.id, privacy: .public) status=\(status, privacy: .public)")
        guard status == noErr else { return false }
        entries[id] = Entry(combo: combo, ref: ref, onDown: onDown, onUp: onUp)
        return true
    }

    public func unregister(id: UInt32) {
        if let entry = entries.removeValue(forKey: id), let ref = entry.ref { UnregisterEventHotKey(ref) }
        if tapEntries.removeValue(forKey: id) != nil, tapEntries.isEmpty { stopTap() }
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

    /// Test hook: a tap-matched shortcut without creating the tap.
    func addTapForTesting(id: UInt32, combo: KeyCombo, onDown: @escaping () -> Void, onUp: @escaping () -> Void = {},
                          onChord: @escaping () -> Void = {}) {
        tapEntries[id] = TapEntry(matcher: ShortcutMatcher(combo: combo), onDown: onDown, onUp: onUp, onChord: onChord)
    }

    /// Feeds one tap event to every tap-matched shortcut. Returns whether to swallow it and the handlers to run; the
    /// tap runs them after returning, so a slow handler never holds the event (macOS disables a tap that stalls).
    func route(_ event: TapEvent) -> (swallow: Bool, handlers: [() -> Void]) {
        var swallow = false
        var handlers: [() -> Void] = []
        for id in tapEntries.keys.sorted() {
            guard var entry = tapEntries[id] else { continue }
            let outcome: ShortcutMatcher.Outcome
            switch event {
            case .keyDown(let key, let flags, let isRepeat): outcome = entry.matcher.keyDown(keyCode: key, cgFlags: flags, isRepeat: isRepeat)
            case .keyUp(let key): outcome = entry.matcher.keyUp(keyCode: key)
            case .flagsChanged(let key, let flags): outcome = entry.matcher.flagsChanged(keyCode: key, cgFlags: flags)
            case .mouseDown: outcome = entry.matcher.mouseDown()
            case .resync(let flags): outcome = entry.matcher.resync(cgFlags: flags)
            }
            tapEntries[id] = entry
            swallow = swallow || outcome.swallow
            switch outcome.action {
            case .down?: handlers.append(entry.onDown)
            case .up?: handlers.append(entry.onUp)
            case .chord?: handlers.append(entry.onChord)
            case nil: break
            }
        }
        return (swallow, handlers)
    }

    // MARK: event tap

    private func startTap() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: hotKeyTapCallback, userInfo: nil) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        return true
    }

    private func stopTap() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CFMachPortInvalidate(port)
        tap = nil
        tapSource = nil
    }

    /// macOS turns a tap off when the main thread is slow or after secure input, and the events meanwhile never reach
    /// it: turn it straight back on and catch up with the modifiers held now, so a release it missed still ends the press.
    fileprivate func reenableTap(timeout: Bool) {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        chirpLog.info("hotkey tap re-enabled timeout=\(timeout, privacy: .public)")
        _ = tapReceived(.resync(cgFlags: CGEventSource.flagsState(.combinedSessionState).rawValue))
    }

    fileprivate func tapReceived(_ event: TapEvent) -> Bool {
        let (swallow, handlers) = route(event)
        if !handlers.isEmpty {
            pendingHandlers += handlers
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.runPendingHandlers() } }
        }
        return swallow
    }

    private func runPendingHandlers() {
        let handlers = pendingHandlers
        pendingHandlers = []
        for handler in handlers { handler() }
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

/// The tap's callback: on the main run loop, so it may enter the main actor. Returns nil to swallow the event.
private func hotKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.rawValue
    let tapEvent: HotKeyCenter.TapEvent
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        MainActor.assumeIsolated { HotKeyCenter.shared.reenableTap(timeout: type == .tapDisabledByTimeout) }
        return Unmanaged.passUnretained(event)
    case .keyDown: tapEvent = .keyDown(keyCode: keyCode, cgFlags: flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    case .keyUp: tapEvent = .keyUp(keyCode: keyCode)
    case .flagsChanged: tapEvent = .flagsChanged(keyCode: keyCode, cgFlags: flags)
    case .leftMouseDown, .rightMouseDown, .otherMouseDown: tapEvent = .mouseDown
    default: return Unmanaged.passUnretained(event)
    }
    let swallow = MainActor.assumeIsolated { HotKeyCenter.shared.tapReceived(tapEvent) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

#endif
