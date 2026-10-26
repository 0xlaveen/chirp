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
    public var compactHeight = false
    public var now: Date
    public init(now: Date) { self.now = now }
}

public enum PrimaryKind: Sendable, Equatable { case fullAccess, openChirp, start, stop, polishing }

/// How the primary control is filled (Pond tokens, #195): koi to start, `record` to stop, moon while polishing,
/// tonal koiContainer for "open Chirp" and the disabled Full Access state.
public enum PrimaryStyle: Sendable, Equatable { case koi, record, moon, tonal }

public struct PrimaryAction: Equatable, Sendable {
    public var kind: PrimaryKind
    public var style: PrimaryStyle
    public var title: String
    /// What VoiceOver reads, when the short visible title needs more ("Stop" → "Stop dictation").
    public var accessibilityLabel: String
    public var symbol: String
    public var hint: String
    public var isEnabled: Bool
}

public struct StyleItem: Equatable, Sendable {
    public var id: String
    public var title: String
    public var isChecked: Bool
}

/// The leading glyph of the status strip.
public enum StripGlyph: Sendable, Equatable {
    /// Armed, finished: a koi dot.
    case koiDot
    /// Connecting, listening: the Ripple.
    case ripple
    /// Polishing: the moon ✦.
    case moon
    /// An error or something that needs attention: a `record` ⚠.
    case warning
    /// No session, no Full Access: the quiet brand glyph.
    case idle
}

/// Chirp's capsule chips, in display order. Style sits in the strip; the others take over the suggestion row while
/// they apply. Chips that don't apply are hidden, not disabled.
public enum KeyboardChip: Sendable, Equatable { case undo, cancel, raw, open, style }

/// The three rows of the keyboard: the Chirp strip, the suggestion row (word suggestions, or Chirp's action chips)
/// and the typing keys. All three are always laid out, so the height never depends on the state.
public enum KeyboardRow: Sendable, CaseIterable { case strip, suggestions, keys }

/// What to draw. The typing keys are always enabled and need no flag.
public struct KeyboardScreen: Equatable, Sendable {
    /// The strip's short label: "Ready", "Listening…", "Mac offline". Also a notice such as "Dictation removed".
    public var phaseText: String
    public var glyph: StripGlyph
    /// The elapsed time while recording or "4:12 left" while the session is idle; shown right-aligned in tabular digits.
    public var trailing: String?
    public var elapsed: String?
    public var remaining: String?
    /// The long guidance behind ⓘ (`chirp.keyboard.detail`), including the DEBUG notice. Nil only when there is none.
    public var detail: String?
    /// The DEBUG-retention notice; the strip shows `warningBadge` and ⓘ explains it.
    public var warning: String?
    public var primary: PrimaryAction
    public var chips: [KeyboardChip]
    public var rawTitle: String
    public var rawSecondsLeft: Int?
    /// The Style chip's title: the style's name ("Email"), never "Style:…".
    public var styleTitle: String
    public var styleItems: [StyleItem]
    /// The Style menu's "Private session" item, checked while it is on.
    public var privacyOn: Bool
    public var endEnabled: Bool
    /// Every row, reserved in every state.
    public var rows: [KeyboardRow] { KeyboardRow.allCases }

    public var showsUndo: Bool { chips.contains(.undo) }
    /// The Style chip lives in the strip.
    public var showsStyle: Bool { chips.contains(.style) }
    /// The chips that replace the word suggestions: Undo, Cancel, Use raw, Open Chirp.
    public var actionChips: [KeyboardChip] { chips.filter { $0 != .style } }
    /// Word suggestions give way while Chirp has an action to offer (dictating, polishing, just finished).
    public var showsSuggestions: Bool { actionChips.isEmpty }
}

public enum KeyboardPresenter {
    public static let styleTitles = ["default": "Default", "chat": "Chat", "email": "Email",
                                     "code": "Code", "notes": "Notes", "custom": "Custom"]
    /// The strip's DEBUG badge text; the full sentence is `warning`.
    public static let warningBadge = "DEBUG"
    public static let warningText = "DEBUG recordings kept on the server"
    /// Private session, as in the Style menu.
    public static let privateTitle = "Private session · exclude history"
    public static let infoLabel = "More about this status"
    public static let closeInfoLabel = "Close"

    /// A server-defined style the keyboard has no name for shows its id, in the chip as in the menu.
    public static func styleTitle(_ id: String) -> String { styleTitles[id] ?? id }

    public static func screen(_ i: KeyboardInputs) -> KeyboardScreen {
        let live = i.hasFullAccess && i.phase != nil && (i.leaseUntil ?? .distantPast) > i.now
            && (i.sessionExpiresAt.map { $0 > i.now } ?? true)
        let phase = live ? i.phase : nil
        let recording = phase == .connecting || phase == .listening
        let busy = recording || phase == .correcting
        let line = text(i, live: live, phase: phase)
        let elapsed = recording ? i.recordingStartedAt.map { ClockText.format(i.now.timeIntervalSince($0)) } : nil
        let remaining = live ? i.sessionExpiresAt.map { ClockText.format(ceil($0.timeIntervalSince(i.now))) + " left" } : nil
        let rawLeft = rawSeconds(i)
        let showsUndo = live && !busy && i.isFinal && i.ownsUtterance && i.undoAvailable
        let showsCancel = live && !showsUndo && !i.isFinal && (busy || i.startPending)
        let showsRaw = live && rawLeft != nil && i.isFinal && i.ownsUtterance && !i.rawRequested
        let items = i.availableStyleIDs.map { StyleItem(id: $0, title: styleTitle($0), isChecked: $0 == i.styleID) }
        let showsStyle = live && !busy && !i.startPending && !items.isEmpty
        let showsOpen = i.hasFullAccess && (i.fallback != nil || i.requiresRecovery)
        let warning = i.debugRetention ? warningText : nil
        let notice = live ? i.notice : nil
        var chips: [KeyboardChip] = []
        if showsUndo { chips.append(.undo) }
        if showsCancel { chips.append(.cancel) }
        if showsRaw { chips.append(.raw) }
        if showsOpen { chips.append(.open) }
        if showsStyle { chips.append(.style) }
        return KeyboardScreen(
            phaseText: notice ?? line.label, glyph: notice == nil ? line.glyph : .koiDot,
            trailing: elapsed ?? remaining, elapsed: elapsed, remaining: remaining,
            detail: [line.detail, warning].compactMap { $0 }.joined(separator: "\n\n").nilIfEmpty, warning: warning,
            primary: primary(i, live: live, phase: phase), chips: chips,
            rawTitle: rawLeft.map { "Use raw (\($0)s)" } ?? "Use raw", rawSecondsLeft: rawLeft,
            styleTitle: styleTitle(i.styleID ?? "default"), styleItems: items, privacyOn: i.privacyMode,
            endEnabled: live)
    }

    /// Whole seconds left in the Use raw window, rounded up so the label reaches 1 before it closes.
    private static func rawSeconds(_ i: KeyboardInputs) -> Int? {
        guard let until = i.rawUntil, i.now < until else { return nil }
        return max(1, Int(ceil(until.timeIntervalSince(i.now))))
    }

    private static func primary(_ i: KeyboardInputs, live: Bool, phase: KeyboardPhase?) -> PrimaryAction {
        let open = PrimaryAction(kind: .openChirp, style: .tonal, title: "Open Chirp to start",
                                 accessibilityLabel: "Open Chirp to start a session", symbol: "arrow.up.forward.app",
                                 hint: "Opens Chirp so you can start a dictation session, then return here.", isEnabled: true)
        guard i.hasFullAccess else {
            return PrimaryAction(kind: .fullAccess, style: .tonal, title: "Full Access required",
                                 accessibilityLabel: "Full Access required", symbol: "lock.fill",
                                 hint: "Enable Full Access for Chirp Keyboard in Settings.", isEnabled: false)
        }
        guard live, let phase else { return open }
        switch phase {
        case .connecting, .listening:
            return PrimaryAction(kind: .stop, style: .record, title: "Stop", accessibilityLabel: "Stop dictation",
                                 symbol: "stop.fill", hint: "Stops recording and inserts the text.", isEnabled: true)
        case .correcting:
            return PrimaryAction(kind: .polishing, style: .moon, title: "Polishing…", accessibilityLabel: "Polishing",
                                 symbol: "sparkles", hint: "Chirp is cleaning up the text.", isEnabled: false)
        case .armed, .finished:
            let title = i.startPending ? "Starting…" : "Start dictation"
            return PrimaryAction(kind: .start, style: .koi, title: title, accessibilityLabel: title, symbol: "mic.fill",
                                 hint: "Starts dictating at the cursor.", isEnabled: !i.startPending)
        case .idle, .failed:
            return open
        }
    }

    private struct Line { var label: String; var glyph: StripGlyph; var detail: String? }

    /// The one-line state and the long text behind ⓘ. The label is the short cause for an error ("Mac offline"),
    /// the fix is the guidance.
    private static func text(_ i: KeyboardInputs, live: Bool, phase: KeyboardPhase?) -> Line {
        guard i.hasFullAccess else {
            return Line(label: "Needs Full Access", glyph: .warning,
                        detail: "Open Settings → Chirp → Keyboards and turn on Allow Full Access, then start a session in Chirp. Typing works without it.")
        }
        if let fallback = i.fallback { return Line(label: "Open Chirp", glyph: .warning, detail: fallback) }
        if i.requiresRecovery {
            return Line(label: "Text kept in place", glyph: .warning,
                        detail: "Cursor or text context changed. Recover the dictation in Chirp; automatic replacement is paused.")
        }
        guard live, let phase else {
            return Line(label: "No session", glyph: .idle,
                        detail: "Tap the button to open Chirp and tap Start keyboard session, then come back here with the app switcher.")
        }
        let idle = "Microphone stays active in Chirp. Idle audio is discarded. End session turns it off."
        let error = i.errorCode
        switch phase {
        case .connecting: return Line(label: "Connecting…", glyph: .ripple, detail: "Tap Stop when you are done.")
        case .listening: return Line(label: "Listening…", glyph: .ripple, detail: "Tap Stop when you are done.")
        case .correcting: return Line(label: "Polishing…", glyph: .moon, detail: "Chirp is cleaning up the text.")
        case .armed:
            return Line(label: error?.cause ?? "Ready", glyph: error == nil ? .koiDot : .warning, detail: error?.guidance ?? idle)
        case .finished:
            if i.kept { return Line(label: "Kept what was heard", glyph: error == nil ? .koiDot : .warning, detail: error?.guidance ?? idle) }
            return Line(label: error?.cause ?? "Finished", glyph: error == nil ? .koiDot : .warning, detail: error?.guidance ?? idle)
        case .idle:
            return Line(label: error?.cause ?? "Session idle", glyph: error == nil ? .idle : .warning,
                        detail: error?.guidance ?? "Open Chirp to start the session again.")
        case .failed:
            let code = error ?? .unknown
            return Line(label: code.cause, glyph: .warning, detail: code.guidance)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
