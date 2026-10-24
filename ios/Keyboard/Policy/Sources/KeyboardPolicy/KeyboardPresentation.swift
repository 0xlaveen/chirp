import Foundation

/// Mirror of `ChirpIOSCore.SessionPhase` (same raw values); this package has no Shared dependency.
public enum KeyboardPhase: String, Sendable, CaseIterable { case idle, armed, connecting, listening, correcting, finished, failed }

/// Everything the screen depends on, mirrored from bridge state and the adapter's local flags.
public struct KeyboardInputs: Equatable, Sendable {
    public var hasFullAccess = false
    public var phase: KeyboardPhase?
    public var leaseUntil: Date?
    public var sessionExpiresAt: Date?
    public var styleID: String?
    public var availableStyleIDs: [String] = []
    /// The app's Private session switch (history excluded), mirrored so the Style menu can show and flip it.
    public var privacyMode = false
    public var debugRetention = false
    public var errorCode: KeyboardError?
    /// `OwnedInsertion.generation != nil`: this keyboard currently owns an utterance.
    public var ownsUtterance = false
    public var isFinal = false
    public var requiresRecovery = false
    public var rawUntil: Date?
    /// The policy still allows Undo of the landed final (see `OwnedInsertion.canUndo`).
    public var undoAvailable = false
    /// The last final is only what was heard before a failure.
    public var kept = false
    /// A short result of the user's last action, such as "Dictation removed".
    public var notice: String?
    public var rawRequested = false
    public var startPending = false
    public var fallback: String?
    public var recordingStartedAt: Date?
    public var needsGlobe = false
    public var compactHeight = false
    public var now: Date
    public init(now: Date) { self.now = now }
}

public enum PrimaryKind: Sendable, Equatable { case fullAccess, openChirp, start, stop, polishing }

public struct PrimaryAction: Equatable, Sendable {
    public var kind: PrimaryKind
    public var title: String
    public var symbol: String
    public var hint: String
    public var isEnabled: Bool
}

public struct StyleItem: Equatable, Sendable {
    public var id: String
    public var title: String
    public var isChecked: Bool
}

/// What to draw. Space, Delete and Return are always enabled and need no flag.
public struct KeyboardScreen: Equatable, Sendable {
    /// Phase text plus elapsed/remaining labels, joined with " · " (the `chirp.keyboard.status` label).
    public var status: String
    public var phaseText: String
    public var elapsed: String?
    public var remaining: String?
    public var detail: String?
    public var showsDetail: Bool
    public var warning: String?
    public var primary: PrimaryAction
    public var cancelEnabled: Bool
    /// The Cancel slot shows Undo instead: Cancel only applies while recording, Undo only after a final.
    public var showsUndo: Bool
    public var rawEnabled: Bool
    public var rawTitle: String
    public var rawSecondsLeft: Int?
    public var styleEnabled: Bool
    public var styleTitle: String
    public var styleItems: [StyleItem]
    /// The Style menu's "Private session" item, checked while it is on.
    public var privacyOn: Bool
    public var endEnabled: Bool
    public var showsOpenChirp: Bool
    public var showsGlobe: Bool
}

public enum KeyboardPresenter {
    public static let styleTitles = ["default": "Default", "chat": "Chat", "email": "Email",
                                     "code": "Code", "notes": "Notes", "custom": "Custom"]

    /// A server-defined style the keyboard has no name for shows its id, in the button as in the menu.
    public static func styleTitle(_ id: String) -> String { styleTitles[id] ?? id }

    public static func screen(_ i: KeyboardInputs) -> KeyboardScreen {
        let live = i.hasFullAccess && i.phase != nil && (i.leaseUntil ?? .distantPast) > i.now
            && (i.sessionExpiresAt.map { $0 > i.now } ?? true)
        let phase = live ? i.phase : nil
        let recording = phase == .connecting || phase == .listening
        let busy = recording || phase == .correcting
        let (phaseText, detail) = text(i, live: live, phase: phase)
        let elapsed = recording ? i.recordingStartedAt.map { ClockText.format(i.now.timeIntervalSince($0)) } : nil
        let remaining = live ? i.sessionExpiresAt.map { ClockText.format(ceil($0.timeIntervalSince(i.now))) + " left" } : nil
        let rawLeft = rawSeconds(i)
        let showsUndo = live && !busy && i.isFinal && i.ownsUtterance && i.undoAvailable
        let items = i.availableStyleIDs.map { StyleItem(id: $0, title: styleTitle($0), isChecked: $0 == i.styleID) }
        return KeyboardScreen(
            status: ([live ? i.notice ?? phaseText : phaseText] + [elapsed, remaining].compactMap { $0 }).joined(separator: " · "),
            phaseText: live ? i.notice ?? phaseText : phaseText, elapsed: elapsed, remaining: remaining,
            detail: detail, showsDetail: detail != nil && !i.compactHeight,
            warning: i.debugRetention ? "DEBUG recordings kept on the server" : nil,
            primary: primary(i, live: live, phase: phase),
            cancelEnabled: live && (showsUndo || (!i.isFinal && (busy || i.startPending))),
            showsUndo: showsUndo,
            rawEnabled: live && rawLeft != nil && i.isFinal && i.ownsUtterance && !i.rawRequested,
            rawTitle: rawLeft.map { "Use raw (\($0)s)" } ?? "Use raw", rawSecondsLeft: rawLeft,
            styleEnabled: live && !busy && !items.isEmpty,
            styleTitle: "Style: " + styleTitle(i.styleID ?? "default"), styleItems: items, privacyOn: i.privacyMode,
            endEnabled: live,
            showsOpenChirp: i.hasFullAccess && (i.fallback != nil || i.requiresRecovery),
            showsGlobe: i.needsGlobe)
    }

    /// Whole seconds left in the Use raw window, rounded up so the label reaches 1 before it closes.
    private static func rawSeconds(_ i: KeyboardInputs) -> Int? {
        guard let until = i.rawUntil, i.now < until else { return nil }
        return max(1, Int(ceil(until.timeIntervalSince(i.now))))
    }

    private static func primary(_ i: KeyboardInputs, live: Bool, phase: KeyboardPhase?) -> PrimaryAction {
        let open = PrimaryAction(kind: .openChirp, title: "Open Chirp to start session", symbol: "arrow.up.forward.app",
                                 hint: "Opens Chirp so you can start a dictation session, then return here.", isEnabled: true)
        guard i.hasFullAccess else {
            return PrimaryAction(kind: .fullAccess, title: "Full Access required", symbol: "lock.fill",
                                 hint: "Enable Full Access for Chirp Keyboard in Settings.", isEnabled: false)
        }
        guard live, let phase else { return open }
        switch phase {
        case .connecting, .listening:
            return PrimaryAction(kind: .stop, title: "Stop dictation", symbol: "stop.fill",
                                 hint: "Stops recording and inserts the text.", isEnabled: true)
        case .correcting:
            return PrimaryAction(kind: .polishing, title: "Polishing…", symbol: "sparkles",
                                 hint: "Chirp is cleaning up the text.", isEnabled: false)
        case .armed, .finished:
            return PrimaryAction(kind: .start, title: i.startPending ? "Starting…" : "Start dictation", symbol: "mic.fill",
                                 hint: "Starts dictating at the cursor.", isEnabled: !i.startPending)
        case .idle, .failed:
            return open
        }
    }

    private static func text(_ i: KeyboardInputs, live: Bool, phase: KeyboardPhase?) -> (String, String?) {
        guard i.hasFullAccess else {
            return ("Dictation needs Full Access",
                    "Open Settings → Chirp → Keyboards and turn on Allow Full Access, then start a session in Chirp. Space, delete, return and next keyboard work here.")
        }
        if let fallback = i.fallback { return ("Open Chirp", fallback) }
        if i.requiresRecovery {
            return ("Text kept in place",
                    "Cursor or text context changed. Recover the dictation in Chirp; automatic replacement is paused.")
        }
        guard live, let phase else {
            return ("Start a session in Chirp",
                    "Tap the button to open Chirp and tap Start keyboard session, then come back here with the app switcher.")
        }
        let idle = "Microphone stays active in Chirp. Idle audio is discarded. End session turns it off."
        switch phase {
        case .connecting: return ("Connecting…", "Tap Stop when you are done.")
        case .listening: return ("Listening…", "Tap Stop when you are done.")
        case .correcting: return ("Polishing…", "Chirp is cleaning up the text.")
        case .armed: return ("Session armed", i.errorCode?.guidance ?? idle)
        case .finished: return (i.kept ? "Kept what was heard" : "Finished", i.errorCode?.guidance ?? idle)
        case .idle: return ("Session idle", i.errorCode?.guidance ?? "Open Chirp to start the session again.")
        case .failed: return ("Dictation failed", (i.errorCode ?? .unknown).guidance)
        }
    }
}
