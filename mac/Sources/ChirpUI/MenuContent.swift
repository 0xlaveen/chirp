import ChirpCore

/// Launch at login as the system reports it.
public enum LaunchState: Equatable, Sendable {
    case on, off
    /// Registered, but macOS wants the user to allow it in System Settings → General → Login Items.
    case needsApproval
    case unavailable

    public var menuTitle: String {
        switch self {
        case .on, .off: "Launch at Login"
        case .needsApproval: "Launch at Login — approve in System Settings…"
        case .unavailable: "Launch at Login (unavailable for this build)"
        }
    }
}

public enum MenuAction: Equatable, Sendable {
    case toggleCorrection, pickHotkey(String), grantMic, grantAX, toggleLaunch, showSettings, quit
}

public struct MenuEntry: Equatable, Sendable {
    public enum Tone: Sendable { case normal, warning, error }
    public enum Mark: Sendable { case off, on, mixed }

    public var title: String
    public var tone: Tone = .normal
    /// nil for informational lines and separators.
    public var action: MenuAction?
    public var mark: Mark = .off
    public var submenu: [MenuEntry]?
    public var isSeparator = false

    public static let separator = MenuEntry(title: "", isSeparator: true)
    static func line(_ title: String, _ tone: Tone = .normal) -> MenuEntry { MenuEntry(title: title, tone: tone) }
}

/// Everything the menu-bar menu shows, as plain values so the same content feeds the real `NSMenu` and the snapshots.
public struct MenuInputs: Sendable {
    public var state: DictationState = .idle
    public var health: Health?
    public var healthError: String?
    public var debugRetention = false
    public var inputName: String?
    public var correctionOn = false
    public var hotkey: KeyCombo = .controlOptionSpace
    public var micGranted = true
    public var accessibilityGranted = true
    public var launch: LaunchState = .off
    public var launchError: String?

    public init() {}
}

public enum MenuContent {
    public static func entries(_ m: MenuInputs) -> [MenuEntry] {
        var out: [MenuEntry] = []
        switch m.state {
        case .idle: out.append(.line("Chirp — ready"))
        case .connecting: out.append(.line("Connecting…"))
        case .listening: out.append(.line("Listening"))
        case .finalizing: out.append(.line("Finalizing"))
        case .inserting: out.append(.line("Inserting"))
        case .error(let message): out.append(.line(message, .error))
        }
        if let h = m.health {
            out.append(.line("Server: \(h.engine ?? "ok")\(h.ready == false ? " (loading…)" : "")"))
        } else {
            out.append(.line(m.healthError ?? "Server: checking…", .warning))
        }
        if m.debugRetention { out.append(.line("DEBUG: recordings kept on the server", .error)) }
        out.append(.line("Input: \(m.inputName ?? "none — no input device")"))
        out.append(.separator)

        if m.health?.correctionAvailable == true {
            let host = m.health?.correctionHost ?? "a remote LLM"
            let title = m.health?.correctionLeavesMachine == true ? "Correction — sends text to \(host)" : "Correction"
            out.append(MenuEntry(title: title, action: .toggleCorrection, mark: m.correctionOn ? .on : .off))
        } else {
            out.append(.line("Correction (not configured on server)"))
        }
        out.append(MenuEntry(
            title: "Hotkey: \(m.hotkey.title) — tap to toggle, hold to talk",
            submenu: KeyCombo.presets.map {
                MenuEntry(title: $0.title, action: .pickHotkey($0.id), mark: $0 == m.hotkey ? .on : .off)
            }))
        out.append(.separator)

        out.append(m.micGranted ? .line("Microphone: granted ✓")
                   : MenuEntry(title: "Microphone: not granted — Grant…", action: .grantMic))
        out.append(m.accessibilityGranted ? .line("Accessibility: granted ✓")
                   : MenuEntry(title: "Accessibility: not granted — Grant…", action: .grantAX))
        out.append(.separator)

        let launch = MenuEntry(title: m.launch.menuTitle, action: m.launch == .unavailable ? nil : .toggleLaunch,
                               mark: m.launch == .on ? .on : m.launch == .needsApproval ? .mixed : .off)
        out.append(launch)
        if let e = m.launchError { out.append(.line("Launch at Login: \(e)", .error)) }
        out.append(MenuEntry(title: "Settings…", action: .showSettings))
        out.append(MenuEntry(title: "Quit Chirp", action: .quit))
        return out
    }
}
