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
    /// The app's Pause dictation history switch, mirrored so the Style menu can show and flip it.
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
    /// When Undo stops being offered; the row shows the seconds left.
    public var undoUntil: Date?
    /// The last final is only what was heard before a failure.
    public var kept = false
    /// A short result of the user's last action, such as "Dictation removed".
    public var notice: String?
    public var rawRequested = false
    public var startPending = false
    public var fallback: String?
    public var recordingStartedAt: Date?
    public var compactHeight = false
    /// The user is typing on the keys right now (the last few seconds). A not-ready row that only says "No session"
    /// then gives the row back to the word suggestions, which typing needs.
    public var typing = false
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
    /// The one or two words the row shows next to the symbol when the action is the row's call to action ("Open
    /// Chirp"); nil where the symbol alone is the control (the mic, Stop).
    public var rowTitle: String?
    public var symbol: String
    public var hint: String
    public var isEnabled: Bool
}

public struct StyleItem: Equatable, Sendable {
    public var id: String
    public var title: String
    public var isChecked: Bool
}

/// The leading glyph of the top row.
public enum StripGlyph: Sendable, Equatable {
    /// Armed: a koi dot.
    case koiDot
    /// Finished, or a notice such as "Dictation removed": a check.
    case check
    /// Connecting, listening: the Ripple.
    case ripple
    /// Polishing: the moon ✦.
    case moon
    /// An error or something that needs attention: a `record` ⚠.
    case warning
    /// No session, no Full Access: the quiet brand glyph.
    case idle
}

/// Chirp's controls, in display order. Style lives in the options panel; the others show in the top row while they
/// apply. Controls that don't apply are hidden, not disabled.
public enum KeyboardChip: Sendable, Equatable { case undo, cancel, raw, open, style }

/// The two rows of the keyboard: the top row (word suggestions, or Chirp's dictation state, as on Android) and the
/// typing keys. Both are always laid out, so the height never depends on the state.
public enum KeyboardRow: Sendable, CaseIterable { case top, keys }

/// What the one top row shows, mirroring Android's strip.
public enum TopRow: Sendable, Equatable {
    /// Idle: ⋯ options at the leading edge, word suggestions, the small mic at the trailing edge.
    case suggestions
    /// ✕ · Ripple and "Listening…" · elapsed time · the red Stop pill.
    case dictating
    /// ✕ · ✦ "Polishing…" · the disabled moon pill.
    case polishing
    /// ✓ "Finished" · Use raw (n s) · Undo.
    case finished
    /// ✓ and a short result ("Dictation removed"), until it expires.
    case notice
    /// One compact message, ⋯ for the long guidance, and at most one action ("Open Chirp", or the mic to retry).
    case notReady
}

/// What to draw. The typing keys are always enabled and need no flag.
public struct KeyboardScreen: Equatable, Sendable {
    /// The row's short label: "Ready", "Listening…", "Computer offline". Also a notice such as "Dictation removed".
    public var phaseText: String
    public var glyph: StripGlyph
    /// What the top row shows.
    public var topRow: TopRow
    /// The elapsed time while recording or "4:12 left" while the session is idle.
    public var trailing: String?
    /// The ticking elapsed time, shown in the dictating row in tabular digits.
    public var elapsed: String?
    /// "4:12 left": the session's remaining time, a detail of the options panel (never a label in the row).
    public var remaining: String?
    /// The long guidance behind ⓘ (`chirp.keyboard.detail`), including the DEBUG notice. Nil only when there is none.
    public var detail: String?
    /// The DEBUG-retention notice; the row says "Debug retention on" and the options panel explains it.
    public var warning: String?
    public var primary: PrimaryAction
    public var chips: [KeyboardChip]
    public var rawTitle: String
    public var rawSecondsLeft: Int?
    /// "Undo (4s)", like Android's chip; just "Undo" when the deadline is unknown.
    public var undoTitle: String
    public var undoSecondsLeft: Int?
    /// The Style picker's title: the style's name ("Email"), never "Style:…".
    public var styleTitle: String
    public var styleItems: [StyleItem]
    /// The Style menu's "Pause dictation history" item, checked while it is on.
    public var privacyOn: Bool
    public var endEnabled: Bool
    /// Every row, reserved in every state.
    public var rows: [KeyboardRow] { KeyboardRow.allCases }

    public var showsUndo: Bool { chips.contains(.undo) }
    /// The Style picker lives in the options panel.
    public var showsStyle: Bool { chips.contains(.style) }
    /// The controls that show in the top row beside the state: Undo, Cancel, Use raw, Open Chirp.
    public var actionChips: [KeyboardChip] { chips.filter { $0 != .style } }
    /// Word suggestions give way to Chirp's state: dictating, polishing, just finished, a notice, or not ready.
    public var showsSuggestions: Bool { topRow == .suggestions }
}

public enum KeyboardPresenter {
    public static let styleTitles = ["default": "Default", "chat": "Chat", "email": "Email",
                                     "code": "Code", "notes": "Notes", "custom": "Custom"]
    public static let warningText = "DEBUG recordings kept on the server"
    /// Pause dictation history, as in the Style menu and Settings → Privacy & history. It persists until turned
    /// off, so it is not called a private session (docs/copy.md, #271 A2-12).
    public static let privateTitle = "Pause dictation history"
    /// The ⋯ button at the row's leading edge (Android's "Dictation options"): Style, help, End session.
    public static let optionsLabel = "Dictation options"
    /// The row's message while DEBUG retention is on and nothing else needs saying.
    public static let debugLine = "Debug retention on"
    public static let closeInfoLabel = "Close"

    /// A server-defined style the keyboard has no name for shows its id, in the chip as in the menu.
    public static func styleTitle(_ id: String) -> String { styleTitles[id] ?? id }

    public static func screen(_ i: KeyboardInputs) -> KeyboardScreen {
        let live = i.hasFullAccess && i.phase != nil && (i.leaseUntil ?? .distantPast) > i.now
            && (i.sessionExpiresAt.map { $0 > i.now } ?? true)
        let phase = live ? i.phase : nil
        let recording = phase == .connecting || phase == .listening
        let busy = recording || phase == .correcting
        var line = text(i, live: live, phase: phase)
        let elapsed = recording ? i.recordingStartedAt.map { ClockText.format(i.now.timeIntervalSince($0)) } : nil
        let remaining = live ? i.sessionExpiresAt.map { ClockText.format(ceil($0.timeIntervalSince(i.now))) + " left" } : nil
        let rawLeft = rawSeconds(i)
        let undoLeft = i.undoUntil.flatMap { seconds(until: $0, now: i.now) }
        let showsUndo = live && !busy && i.isFinal && i.ownsUtterance && i.undoAvailable
        let showsCancel = live && !showsUndo && !i.isFinal && (busy || i.startPending)
        let showsRaw = live && rawLeft != nil && i.isFinal && i.ownsUtterance && !i.rawRequested
        let items = i.availableStyleIDs.map { StyleItem(id: $0, title: styleTitle($0), isChecked: $0 == i.styleID) }
        let showsStyle = live && !busy && !i.startPending && !items.isEmpty
        let showsOpen = i.hasFullAccess && (i.fallback != nil || i.requiresRecovery)
        let warning = i.debugRetention ? warningText : nil
        let notice = live ? i.notice : nil
        var row: TopRow
        if recording || i.startPending { row = .dictating }
        else if phase == .correcting { row = .polishing }
        else if notice != nil { row = .notice }
        else if !live || showsOpen || phase == .idle || phase == .failed { row = .notReady }
        else if showsUndo || showsRaw { row = .finished }
        else if i.errorCode != nil || warning != nil { row = .notReady }
        else { row = .suggestions }
        // A passive "No session" / "Needs Full Access" row never takes the suggestions from someone who is typing:
        // the row shows them again, with ⋯ and the Open Chirp action as the small trailing icon, until they stop.
        let passive = i.errorCode == nil && i.fallback == nil && !i.requiresRecovery && !showsOpen
        if row == .notReady && i.typing && passive && (!live || phase == .idle) { row = .suggestions }
        // Starting is already dictating: the same row, until the session confirms.
        if i.startPending && !recording && phase != .correcting { line = Line(label: "Starting…", glyph: .ripple, detail: line.detail) }
        if row == .notReady && warning != nil && i.errorCode == nil && live && !showsOpen {
            line = Line(label: debugLine, glyph: .warning, detail: line.detail)
        }
        if row == .finished && line.glyph == .koiDot { line.glyph = .check }
        var chips: [KeyboardChip] = []
        if showsUndo { chips.append(.undo) }
        if showsCancel { chips.append(.cancel) }
        if showsRaw { chips.append(.raw) }
        if showsOpen { chips.append(.open) }
        if showsStyle { chips.append(.style) }
        return KeyboardScreen(
            phaseText: row == .notice ? notice ?? line.label : line.label, glyph: row == .notice ? .check : line.glyph,
            topRow: row, trailing: elapsed ?? remaining, elapsed: elapsed, remaining: remaining,
            detail: [line.detail, warning].compactMap { $0 }.joined(separator: "\n\n").nilIfEmpty, warning: warning,
            primary: primary(i, live: live, phase: phase), chips: chips,
            rawTitle: rawLeft.map { "Use raw (\($0)s)" } ?? "Use raw", rawSecondsLeft: rawLeft,
            undoTitle: undoLeft.map { "Undo (\($0)s)" } ?? "Undo", undoSecondsLeft: undoLeft,
            styleTitle: styleTitle(i.styleID ?? "default"), styleItems: items, privacyOn: i.privacyMode,
            endEnabled: live)
    }

    /// Whole seconds left in the Use raw window, rounded up so the label reaches 1 before it closes.
    private static func rawSeconds(_ i: KeyboardInputs) -> Int? { i.rawUntil.flatMap { seconds(until: $0, now: i.now) } }

    private static func seconds(until: Date, now: Date) -> Int? {
        guard now < until else { return nil }
        return max(1, Int(ceil(until.timeIntervalSince(now))))
    }

    private static func primary(_ i: KeyboardInputs, live: Bool, phase: KeyboardPhase?) -> PrimaryAction {
        let open = PrimaryAction(kind: .openChirp, style: .tonal, title: "Open Chirp to start",
                                 accessibilityLabel: "Open Chirp to start a session", rowTitle: "Open Chirp", symbol: "arrow.up.forward.app",
                                 hint: "Opens Chirp so you can start a dictation session, then return here.", isEnabled: true)
        guard i.hasFullAccess else {
            return PrimaryAction(kind: .fullAccess, style: .tonal, title: "Full Access required",
                                 accessibilityLabel: "Full Access required", rowTitle: nil, symbol: "lock.fill",
                                 hint: "Enable Full Access for Chirp Keyboard in Settings.", isEnabled: false)
        }
        guard live, let phase else { return open }
        switch phase {
        case .connecting, .listening:
            return PrimaryAction(kind: .stop, style: .record, title: "Stop", accessibilityLabel: "Stop dictation",
                                 rowTitle: nil, symbol: "stop.fill", hint: "Stops recording and inserts the text.", isEnabled: true)
        case .correcting:
            return PrimaryAction(kind: .polishing, style: .moon, title: "Polishing…", accessibilityLabel: "Polishing",
                                 rowTitle: nil, symbol: "sparkles", hint: "Chirp is cleaning up the text.", isEnabled: false)
        case .armed, .finished:
            let title = i.startPending ? "Starting…" : "Start dictation"
            return PrimaryAction(kind: .start, style: .koi, title: title, accessibilityLabel: title, rowTitle: nil, symbol: "mic.fill",
                                 hint: "Starts dictating at the cursor.", isEnabled: !i.startPending)
        case .idle, .failed:
            return open
        }
    }

    private struct Line { var label: String; var glyph: StripGlyph; var detail: String? }

    /// The one-line state and the long text behind ⓘ. The label is the short cause for an error ("Computer offline"),
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
