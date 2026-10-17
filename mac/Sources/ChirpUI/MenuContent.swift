import ChirpCore

/// Whether Chirp starts at login: the presence of its LaunchAgent.
public enum LaunchState: Equatable, Sendable {
    case on, off
    /// Not running from an app bundle (e.g. `swift run`), so there is no app to launch.
    case unavailable

    public static let menuTitle = "Launch at Login"
}

public enum MenuAction: Equatable, Sendable {
    case toggleDictation, pickInput(String?), toggleCleanup, toggleShowRaw, pickHotkey(String)
    case copyDoctor, grantMic, grantAX, toggleLaunch, showSettings, showAbout, quit

    /// What the AppKit item carries to its action method.
    public var payload: String? {
        switch self {
        case .pickInput(let uid): uid
        case .pickHotkey(let id): id
        default: nil
        }
    }
}

public struct MenuEntry: Equatable, Sendable {
    public enum Tone: Sendable { case normal, ok, active, warning, error }
    public enum Mark: Sendable { case off, on, mixed }

    public var title: String
    public var subtitle: String?
    /// SF Symbol name, tinted by `tone` when the tone is not `.normal`.
    public var symbol: String?
    public var tone: Tone = .normal
    /// Tints the symbol alone (the server's status dot) when the title keeps its normal colour.
    public var symbolTone: Tone?
    /// nil for informational lines, headers and separators.
    public var action: MenuAction?
    public var mark: Mark = .off
    public var submenu: [MenuEntry]?
    public var isSeparator = false
    /// A native section header ("Clean-up", "Server", …).
    public var isHeader = false
    /// ⌘-key equivalent shown at the right ("," and "q").
    public var keyEquivalent: String?
    /// The first row of the header block: app icon, name and hotkey hint. The rows after it, up to the next separator
    /// (status, debug warning), belong to the same block.
    public var showsAppIcon = false

    public static let separator = MenuEntry(title: "", isSeparator: true)
    static func header(_ title: String) -> MenuEntry { MenuEntry(title: title, isHeader: true) }
    static func line(_ title: String, symbol: String? = nil, _ tone: Tone = .normal) -> MenuEntry {
        MenuEntry(title: title, symbol: symbol, tone: tone)
    }
}

/// Everything the menu-bar menu shows, as plain values so the same content feeds the real `NSMenu` and the snapshots.
public struct MenuInputs: Sendable {
    public var state: DictationState = .idle
    public var health: Health?
    public var healthError: String?
    public var debugRetention = false
    /// Every input device, the system default among them, and the one the user picked (nil follows the default).
    public var inputs: [AudioInput] = []
    public var defaultInput: AudioInput?
    public var chosenInputUID: String?
    public var cleanupOn = false
    public var showRawAfterCleanup = true
    public var hotkey: KeyCombo = .controlOptionSpace
    public var serverURL = ServerConfig.defaultURL.absoluteString
    public var micGranted = true
    public var accessibilityGranted = true
    public var launch: LaunchState = .off
    public var launchError: String?

    public init() {}
}

public enum MenuContent {
    /// The one-line status under the header: what Chirp is doing, or what is wrong.
    public static func status(_ m: MenuInputs) -> MenuEntry {
        switch m.state {
        case .connecting: return .line("Connecting…", symbol: "circle.fill", .active)
        case .listening: return .line("Listening", symbol: "circle.fill", .active)
        case .finalizing: return .line("Finalizing", symbol: "circle.fill", .active)
        case .inserting: return .line("Inserting", symbol: "circle.fill", .active)
        case .error(let message): return .line(message, symbol: "exclamationmark.triangle.fill", .error)
        case .idle: break
        }
        guard let h = m.health else {
            return m.healthError == nil ? .line("Checking server…", symbol: "circle.fill", .warning)
                                        : .line("Server unreachable", symbol: "circle.fill", .error)
        }
        return h.ready == false ? .line("Loading model…", symbol: "circle.fill", .warning)
                                : .line("Ready", symbol: "circle.fill", .ok)
    }

    public static func entries(_ m: MenuInputs) -> [MenuEntry] {
        var out: [MenuEntry] = []

        // Header: name, hotkey hint, status.
        out.append(MenuEntry(title: "Chirp", subtitle: "\(m.hotkey.title) — tap to toggle, hold to talk", showsAppIcon: true))
        out.append(status(m))
        if m.debugRetention {
            out.append(.line("DEBUG retention ON — recordings kept", symbol: "record.circle.fill", .error))
        }
        out.append(.separator)

        // Dictation: the same toggle as the hotkey, for discoverability. The header already shows the hotkey, so the
        // row carries no key equivalent (AppKit would draw ⌃⌥Space in separate columns and it only works with the menu open).
        switch m.state {
        case .idle, .error:
            out.append(MenuEntry(title: "Start dictation", symbol: "mic.fill", action: .toggleDictation))
        case .connecting, .listening:
            out.append(MenuEntry(title: "Stop dictation", symbol: "stop.fill", action: .toggleDictation))
        case .finalizing, .inserting:
            out.append(MenuEntry(title: "Start dictation", symbol: "mic.fill"))
        }
        out.append(inputPicker(m))
        out.append(MenuEntry(
            title: "Hotkey", subtitle: m.hotkey.title, symbol: "command",
            submenu: KeyCombo.presets.map {
                MenuEntry(title: $0.title, action: .pickHotkey($0.id), mark: $0 == m.hotkey ? .on : .off)
            }))
        out.append(.separator)

        out.append(contentsOf: cleanup(m))
        out.append(.separator)

        out.append(contentsOf: server(m))

        if !m.micGranted || !m.accessibilityGranted {
            out.append(.separator)
            out.append(.header("Permissions needed"))
            if !m.micGranted {
                out.append(MenuEntry(title: "Allow Microphone…", subtitle: "Needed to hear you", symbol: "mic.slash.fill",
                                     tone: .warning, action: .grantMic))
            }
            if !m.accessibilityGranted {
                out.append(MenuEntry(title: "Allow Accessibility…", subtitle: "Needed to type into other apps",
                                     symbol: "hand.raised.fill", tone: .warning, action: .grantAX))
            }
        }
        out.append(.separator)

        out.append(MenuEntry(title: LaunchState.menuTitle, subtitle: m.launchError.map { "Couldn’t change it: \($0)" },
                             symbol: "power", symbolTone: m.launchError == nil ? nil : .error,
                             action: m.launch == .unavailable ? nil : .toggleLaunch, mark: m.launch == .on ? .on : .off))
        out.append(MenuEntry(title: "Settings…", symbol: "gearshape", action: .showSettings, keyEquivalent: ","))
        out.append(MenuEntry(title: "About Chirp", symbol: "info.circle", action: .showAbout))
        out.append(MenuEntry(title: "Quit Chirp", symbol: "power.circle", action: .quit, keyEquivalent: "q"))
        return out
    }

    /// "Input Device": follows the system default unless one is picked and still connected.
    static func inputPicker(_ m: MenuInputs) -> MenuEntry {
        let picked = InputSelection.resolve(chosen: m.chosenInputUID, available: m.inputs)
        guard !m.inputs.isEmpty || m.defaultInput != nil else {
            return MenuEntry(title: "Input Device", subtitle: "No input device", symbol: "mic.slash", tone: .warning)
        }
        var subtitle = picked?.name ?? m.defaultInput?.name ?? "System default"
        if m.chosenInputUID != nil, picked == nil { subtitle += " (picked device not connected)" }
        var sub = [MenuEntry(title: "System Default", subtitle: m.defaultInput?.name, action: .pickInput(nil),
                             mark: picked == nil ? .on : .off)]
        if !m.inputs.isEmpty { sub.append(.separator) }
        sub += m.inputs.map { MenuEntry(title: $0.name, action: .pickInput($0.uid), mark: $0 == picked ? .on : .off) }
        return MenuEntry(title: "Input Device", subtitle: subtitle, symbol: "mic", submenu: sub)
    }

    /// Clean-up maps to the wire `correction` flag; the server says whether it is configured and where text goes.
    /// A server without clean-up gets one explanatory row and nothing to toggle, and "Show raw" only appears while
    /// clean-up is on, so no row is ever greyed out yet checked.
    static func cleanup(_ m: MenuInputs) -> [MenuEntry] {
        if let h = m.health, !h.correctionAvailable {
            return [.header("Clean-up"), .line("Clean-up: off on server — see README", symbol: "sparkles")]
        }
        var toggle = MenuEntry(title: "Clean up text", symbol: "sparkles", action: .toggleCleanup, mark: m.cleanupOn ? .on : .off)
        if let h = m.health {
            toggle.subtitle = h.correctionLeavesMachine == true ? "Sends text to \(h.correctionHost ?? "a remote LLM")"
                                                                : "Runs on this Mac"
        } else {
            toggle.subtitle = "Server unreachable"
        }
        var out: [MenuEntry] = [.header("Clean-up"), toggle]
        if m.cleanupOn {
            out.append(MenuEntry(title: "Show raw after clean-up", subtitle: "Offer “Use raw” for 5 seconds",
                                 symbol: "arrow.uturn.backward", action: .toggleShowRaw, mark: m.showRawAfterCleanup ? .on : .off))
        }
        return out
    }

    /// The server's state in words and tone, for the menu and the Settings window.
    public static func serverStatus(health: Health?, healthError: String?) -> (text: String, tone: MenuEntry.Tone) {
        switch health {
        case nil: healthError == nil ? ("Checking…", .warning) : ("Unreachable", .error)
        case let h? where h.ready == false: ("Loading model…", .warning)
        case let h?: (h.engine ?? "Connected", .ok)
        }
    }

    static func server(_ m: MenuInputs) -> [MenuEntry] {
        let (subtitle, tone) = serverStatus(health: m.health, healthError: m.healthError)
        return [
            .header("Server"),
            MenuEntry(title: m.serverURL, subtitle: subtitle, symbol: "circle.fill", symbolTone: tone, action: .showSettings),
            MenuEntry(title: "Open doctor output", subtitle: "Copies the chirp-server doctor command",
                      symbol: "stethoscope", action: .copyDoctor),
        ]
    }
}
