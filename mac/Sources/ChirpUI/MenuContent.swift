import ChirpCore

/// Whether Chirp starts at login: the presence of its LaunchAgent.
public enum LaunchState: Equatable, Sendable {
    case on, off
    /// Not running from an app bundle (e.g. `swift run`), so there is no app to launch.
    case unavailable
}

public enum MenuAction: Equatable, Sendable {
    case toggleDictation, useRaw, pickInput(String?), toggleCleanup, toggleShowChanges, pickStyle(String), pickSound(String)
    case copyDoctor, showSettings, editStyles, showSetup, showAbout, quit

    /// What the AppKit item carries to its action method.
    public var payload: String? {
        switch self {
        case .pickInput(let uid): uid
        case .pickStyle(let id): id
        case .pickSound(let id): id
        default: nil
        }
    }
}

/// One row of the menu: a title, then (for the top-level rows) a grey value or shortcut at the right.
public struct MenuEntry: Equatable, Sendable {
    public enum Tone: Sendable { case normal, ok, active, warning, error }
    public enum Mark: Sendable { case off, on, mixed }

    public var title: String
    /// The current value of a submenu row ("Default", "BOYA CM40"), right-aligned in secondary grey. Already truncated.
    public var value: String?
    /// The untruncated value, for VoiceOver, when `value` was shortened.
    public var fullValue: String?
    /// A keyboard shortcut shown in grey at the right ("⌃⌥Space").
    public var shortcut: String?
    public var tone: Tone = .normal
    /// nil for informational lines and rows that only open a submenu.
    public var action: MenuAction?
    public var mark: Mark = .off
    public var submenu: [MenuEntry]?
    public var isSeparator = false
    /// ⌘-key equivalent that really triggers the row ("," and "q"); its glyphs are the `shortcut`.
    public var keyEquivalent: String?

    public static let separator = MenuEntry(title: "", isSeparator: true)

    public var isEnabled: Bool { action != nil || submenu != nil }

    /// What VoiceOver reads: the title and the full value or shortcut.
    public var accessibilityLabel: String {
        [title, fullValue ?? value ?? shortcut].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The header block: the name, a one-line status and the main switch.
public struct MenuHeader: Equatable, Sendable {
    public var title = "Chirp"
    public var status: String
    public var tone: MenuEntry.Tone
    /// The switch: on while Chirp is running, off while it is paused.
    public var isOn: Bool

    public var accessibilityLabel: String { "\(title), \(status)" }
}

/// Everything the menu-bar menu shows, as plain values so the same content feeds the real `NSMenu` and the snapshots.
public struct MenuInputs: Sendable {
    public var state: DictationState = .idle
    public var health: Health?
    public var healthError: String?
    public var debugRetention = false
    /// The menu's switch is off: the hotkey is released and the bird is dimmed.
    public var paused = false
    /// The dictation hotkey is registered (it is not while paused, or when another app owns the shortcut).
    public var hotkeyRegistered = true
    /// Every input device, the system default among them, and the one the user picked (nil follows the default).
    public var inputs: [AudioInput] = []
    public var defaultInput: AudioInput?
    public var chosenInputUID: String?
    public var cleanupOn = false
    public var showChanges = false
    /// The 5-second "Use raw" window after a cleaned insertion is open; `rawOfferKey` is its hotkey when it has one.
    public var rawOfferOpen = false
    public var rawOfferKey: String?
    /// The default clean-up style (a profile id); a per-app rule can override it for one dictation.
    public var styleID = CorrectionProfile.defaultID
    public var hotkey: KeyCombo = .controlOptionSpace
    public var soundsEnabled = false
    public var soundPack: SoundPack = .default
    public var serverURL = ServerConfig.defaultURL.absoluteString
    public var micGranted = true
    public var accessibilityGranted = true

    public init() {}

    /// Something Set Up Chirp would fix: a missing permission, or a server that cannot be reached.
    public var setupIncomplete: Bool {
        !micGranted || !accessibilityGranted || (health == nil && healthError != nil)
    }
}

public enum MenuContent {
    /// Longest value shown in a row; longer ones end in "…" so a long microphone name never stretches the menu.
    public static let valueLimit = 22

    /// `text` cut to `limit` characters (grapheme clusters) with a trailing "…".
    public static func truncated(_ text: String, limit: Int = valueLimit) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The header: the name, what Chirp is doing or what is wrong, and the switch.
    public static func header(_ m: MenuInputs) -> MenuHeader {
        let (status, tone) = statusLine(m)
        return MenuHeader(status: status, tone: tone, isOn: !m.paused)
    }

    /// The one-line status under the name. What Chirp is doing wins over the server's state, which wins over the
    /// debug warning; the idle line carries the hotkey.
    public static func statusLine(_ m: MenuInputs) -> (text: String, tone: MenuEntry.Tone) {
        if m.paused { return ("Paused", .normal) }
        switch m.state {
        case .connecting: return ("Connecting…", .active)
        case .listening: return ("Listening…", .active)
        case .finalizing: return ("Finalizing…", .active)
        case .correcting: return ("Polishing…", .active)
        case .inserting: return ("Inserting…", .active)
        case .error(let message): return (message, .error)
        case .idle: break
        }
        guard let h = m.health else {
            return m.healthError == nil ? ("Checking server…", .warning) : ("Server unreachable", .error)
        }
        if h.ready == false { return ("Loading model…", .warning) }
        if m.debugRetention { return ("DEBUG recordings kept", .error) }
        return m.hotkeyRegistered ? ("Ready · \(m.hotkey.title)", .normal) : ("Ready · shortcut in use elsewhere", .warning)
    }

    /// The rows below the header.
    public static func entries(_ m: MenuInputs) -> [MenuEntry] {
        var out: [MenuEntry] = [.separator]

        // Dictation: the same toggle as the hotkey. Off while paused or while a dictation is wrapping up.
        let shortcut = m.paused || !m.hotkeyRegistered ? nil : m.hotkey.title
        switch m.state {
        case .idle, .error:
            out.append(MenuEntry(title: "Start Dictation", shortcut: shortcut, action: m.paused ? nil : .toggleDictation))
        case .connecting, .listening:
            out.append(MenuEntry(title: "Stop Dictation", shortcut: shortcut, action: .toggleDictation))
        case .finalizing, .correcting, .inserting:
            out.append(MenuEntry(title: "Start Dictation", shortcut: shortcut))
        }
        if m.rawOfferOpen {
            out.append(MenuEntry(title: "Use Raw for Last Dictation", shortcut: m.rawOfferKey, action: .useRaw))
        }
        out.append(.separator)

        out.append(cleanupMenu(m))
        out.append(microphoneMenu(m))
        out.append(soundsMenu(m))
        out.append(serverMenu(m))
        out.append(.separator)

        if m.setupIncomplete { out.append(MenuEntry(title: "Set Up Chirp…", action: .showSetup)) }
        out.append(MenuEntry(title: "Settings…", shortcut: "⌘,", action: .showSettings, keyEquivalent: ","))
        out.append(MenuEntry(title: "About Chirp", action: .showAbout))
        out.append(.separator)
        out.append(MenuEntry(title: "Quit Chirp", shortcut: "⌘Q", action: .quit, keyEquivalent: "q"))
        return out
    }

    private static func row(_ title: String, value: String, tone: MenuEntry.Tone = .normal, submenu: [MenuEntry]?) -> MenuEntry {
        let short = truncated(value)
        return MenuEntry(title: title, value: short, fullValue: short == value ? nil : value, tone: tone, submenu: submenu)
    }

    // MARK: clean-up

    /// "Clean-up": the toggle, the styles, "Show changes after clean-up" and a way into the style editor. The value is
    /// the default style, or Off. A server without clean-up gets one explanatory line and nothing to toggle.
    static func cleanupMenu(_ m: MenuInputs) -> MenuEntry {
        let edit = MenuEntry(title: "Edit Styles…", action: .editStyles)
        if let h = m.health, !h.correctionAvailable {
            return row("Clean-up", value: "Unavailable", submenu: [
                MenuEntry(title: "Clean-up is off on the server"), .separator, edit])
        }
        var sub = [MenuEntry(title: "Clean up Text", action: .toggleCleanup, mark: m.cleanupOn ? .on : .off), .separator]
        if m.health == nil || m.health?.correctionProfiles != nil {
            for p in CorrectionProfile.offered(by: m.health) {
                sub.append(MenuEntry(title: p.name, action: .pickStyle(p.id), mark: p.id == m.styleID ? .on : .off))
            }
            sub.append(.separator)
        }
        sub.append(MenuEntry(title: "Show Changes after Clean-up", action: .toggleShowChanges, mark: m.showChanges ? .on : .off))
        sub.append(.separator)
        sub.append(edit)
        let value = m.cleanupOn ? CorrectionProfile.name(for: m.styleID, in: m.health) : "Off"
        return row("Clean-up", value: value, submenu: sub)
    }

    // MARK: microphone

    /// "Microphone": follows the system default unless one is picked and still connected.
    static func microphoneMenu(_ m: MenuInputs) -> MenuEntry {
        guard !m.inputs.isEmpty || m.defaultInput != nil else {
            return MenuEntry(title: "Microphone", value: "None", tone: .warning)
        }
        let picked = InputSelection.resolve(chosen: m.chosenInputUID, available: m.inputs)
        let value = picked?.name ?? m.defaultInput?.name ?? "System Default"
        var sub = [MenuEntry(title: "Follow System Default", action: .pickInput(nil), mark: picked == nil ? .on : .off)]
        if !m.inputs.isEmpty { sub.append(.separator) }
        sub += m.inputs.map { MenuEntry(title: $0.name, action: .pickInput($0.uid), mark: $0 == picked ? .on : .off) }
        return row("Microphone", value: value, submenu: sub)
    }

    // MARK: sounds

    /// "Sounds": Off, the packs, Custom… (which asks for files in Settings until there are some).
    static func soundsMenu(_ m: MenuInputs) -> MenuEntry {
        let current = SoundChoice.current(enabled: m.soundsEnabled, pack: m.soundPack)
        var sub: [MenuEntry] = []
        for choice in SoundChoice.menuOrder {
            if choice == .pack(.custom) { sub.append(.separator) }
            let title: String
            switch choice {
            case .off: title = "Off"
            case .pack(let p): title = p.title
            }
            sub.append(MenuEntry(title: title, action: .pickSound(choice.id), mark: choice == current ? .on : .off))
            if choice == .off { sub.append(.separator) }
        }
        var value = "Off"
        if m.soundsEnabled { value = m.soundPack == .custom ? "Custom" : m.soundPack.title }
        return row("Sounds", value: value, submenu: sub)
    }

    // MARK: server

    /// "This Mac" for a server on loopback, else its host name.
    public static func serverLocation(_ urlString: String) -> String {
        let config = ServerConfig.load(urlString: urlString)
        return config.isLoopback ? "This Mac" : config.host
    }

    /// The server's state in words and tone, for the menu and the Settings window.
    public static func serverStatus(health: Health?, healthError: String?) -> (text: String, tone: MenuEntry.Tone) {
        switch health {
        case nil: healthError == nil ? ("Checking…", .warning) : ("Unreachable", .error)
        case let h? where h.ready == false: ("Loading model…", .warning)
        case let h?: (h.engine ?? "Connected", .ok)
        }
    }

    /// "Server": where it is, then its URL, engine and status as disabled lines, and the doctor command.
    static func serverMenu(_ m: MenuInputs) -> MenuEntry {
        let status = serverStatus(health: m.health, healthError: m.healthError)
        let state: String
        switch m.health {
        case nil: state = m.healthError == nil ? "Checking…" : "Unreachable"
        case let h? where h.ready == false: state = "Loading model…"
        default: state = "Ready"
        }
        var sub = [MenuEntry(title: m.serverURL)]
        if let engine = m.health?.engine { sub.append(MenuEntry(title: "Engine: \(engine)")) }
        sub.append(MenuEntry(title: "Status: \(state)", tone: status.tone == .error ? .error : .normal))
        sub.append(.separator)
        sub.append(MenuEntry(title: "Copy Doctor Command", action: .copyDoctor))
        return row("Server", value: serverLocation(m.serverURL), tone: status.tone == .error ? .error : .normal, submenu: sub)
    }
}
