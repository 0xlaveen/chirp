import ChirpCore
import Foundation
import Observation

/// The Notes window's three layouts.
public enum NotesTab: String, CaseIterable, Sendable {
    case notes, transcript, split

    public var title: String {
        switch self {
        case .notes: "Notes"
        case .transcript: "Transcript"
        case .split: "Split"
        }
    }
}

/// The Notes window's wording, in one place so the controller, the snapshots and the tests agree.
public enum NotesStatus {
    public static let connecting = "Connecting…"
    public static let listening = "Listening…"
    public static let updating = "Updating notes…"
    public static let finishing = "Finishing…"
    public static let reorganizing = "Organizing notes…"
    public static let placeholder = "Type notes, or press Record (\(MenuContent.notesHotkeyTitle))…"
    public static let reorganized = "Notes organized"
    public static let organized = "Organized"
    public static let organizeLabel = "Organize"
    public static let organizeHelp = "Clean up and organize notes"

    /// "Organizing notes… 2/4" while Organize works through its steps.
    public static func organizing(_ step: Int, of total: Int) -> String { "Organizing notes… \(step)/\(total)" }

    /// "Couldn’t organize 1 section (rejected: novel_name) — kept as is".
    public static func organizeFailed(_ count: Int, reason: String?) -> String {
        "Couldn’t organize \(count) section\(count == 1 ? "" : "s")\(reason.map { " (\($0))" } ?? "") — kept as is"
    }
    public static let stopped = "Stopped"
    public static let empty = "Press Record or \(MenuContent.notesHotkeyTitle) to start taking notes."
    public static let privacy = "Notes stay in memory until you save them."
}

/// What the Notes window shows: a mirror of `NotesRecorder` plus the window's own choices. In memory only; the
/// controller stores just the preferences (the tab, "Structure notes", "Auto-reorganize" and Edit/Preview).
@MainActor @Observable
public final class NotesModel {
    public var state: NotesRecorderState = .idle
    public var document = NotesDocument()
    public var structuring: StructuringStatus = .idle
    /// Audio recorded into the document, seconds.
    public var elapsed: TimeInterval = 0
    public var tab: NotesTab = .notes
    /// The transcript shows each segment's raw text.
    public var showRaw = false
    /// The user's "Structure notes" toggle.
    public var structureEnabled = true
    public var privacyLine = NotesStatus.privacy
    public var debugRetention = false
    /// The server is on this Mac, so "Manage Local Models…" can open the models window.
    public var canManageModels = false
    public var reduceMotion = false
    /// The Notes pane shows the read-only Preview instead of the editor.
    public var preview = false
    /// The user's "Auto-reorganize" toggle.
    public var autoReorganize = true
    public var reorganizeStatus: ReorganizeStatus = .idle
    /// The "Organized · Undo" chip was dismissed for the reorganize applied at this time.
    public var dismissedChip: TimeInterval?
    /// The editor has keyboard focus (set by the editor).
    public var editorFocused = false
    /// Bumped to ask the editor to take keyboard focus (the empty state was clicked, the window opened with focus).
    public var focusRequest = 0

    /// AI changes the editor has not replayed yet. Not observed: the editor drains them as they arrive.
    @ObservationIgnored public private(set) var pendingChanges: [NotesTextChange] = []
    /// The editor that owns the hooks below (the newest one on screen).
    @ObservationIgnored public var editorOwner: ObjectIdentifier?
    /// Set by the editor while it is on screen; called whenever changes are queued.
    @ObservationIgnored public var onPendingChanges: (() -> Void)?

    public var onRecordToggle: () -> Void = {}
    public var onCopy: () -> Void = {}
    public var onSave: () -> Void = {}
    public var onNew: () -> Void = {}
    public var onManageModels: () -> Void = {}
    public var onStructureToggle: (Bool) -> Void = { _ in }
    public var onTabChange: (NotesTab) -> Void = { _ in }
    /// The editor changed the text: the range (UTF-16, in the old text) and its replacement.
    @ObservationIgnored public var onUserEdit: (NSRange, String, NotesTextChange.Kind) -> Void = { _, _, _ in }
    public var onReorganize: () -> Void = {}
    public var onAutoReorganizeToggle: (Bool) -> Void = { _ in }
    public var onPreviewToggle: (Bool) -> Void = { _ in }
    /// The caret is in the AI tail with focus, and whether IME is composing.
    @ObservationIgnored public var onEditorFocus: (_ inTail: Bool, _ composing: Bool) -> Void = { _, _ in }
    /// Set by the editor: undoes the last reorganize if it is still the top undo group (the chip's Undo).
    @ObservationIgnored public var undoReorganize: () -> Void = {}

    public init() {}

    /// Queues AI changes for the editor. With no editor on screen they are dropped: an editor that appears loads
    /// `document.text` as it is then.
    public func enqueue(_ changes: [NotesTextChange]) {
        guard !changes.isEmpty, let sink = onPendingChanges else { return }
        pendingChanges += changes
        sink()
    }

    public func takePendingChanges() -> [NotesTextChange] {
        defer { pendingChanges.removeAll() }
        return pendingChanges
    }

    public var isRecording: Bool { state.isCapturing }
    public var isBusy: Bool { state == .stopping }
    public var hasContent: Bool { !document.isEmpty }
    /// Record or Stop can be pressed (not while the last segment finishes).
    public var canToggle: Bool { !isBusy }
    public var canExport: Bool { hasContent && !isBusy }
    public var canNew: Bool { !state.isActive && (hasContent || !document.segments.isEmpty) }

    public var elapsedText: String {
        let s = max(0, Int(elapsed))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    public var isError: Bool { if case .error = state { true } else { false } }

    public var statusText: String {
        switch state {
        case .idle: ""
        case .starting: NotesStatus.connecting
        case .recording:
            isReorganizing ? reorganizingText : structuring == .running ? NotesStatus.updating : NotesStatus.listening
        case .stopping: (isReorganizing ? reorganizingText : NotesStatus.finishing) + finishingSuffix
        case .stopped where isReorganizing, .idle where isReorganizing: reorganizingText
        case .stopped: NotesStatus.stopped
        case .error(let message): message
        }
    }

    /// An append pass is running on the AI tail.
    public var isUpdating: Bool { structuring == .running }

    public var isReorganizing: Bool { reorganizeStatus.isRunning }

    private var reorganizingText: String {
        if case .organizing(let step, let total) = reorganizeStatus { return NotesStatus.organizing(step, of: total) }
        return NotesStatus.reorganizing
    }

    /// How long Stop has been finishing, while it is (set by the controller once a second).
    public var finishingElapsed: TimeInterval?

    /// " · 12 s" once Stop has taken a few seconds, so a long finish never looks stuck.
    private var finishingSuffix: String {
        guard let e = finishingElapsed, e >= 3 else { return "" }
        return " · \(Int(e)) s"
    }

    /// The empty-state art: no notes, nothing recorded yet, and the editor not focused (a click focuses it).
    public var showsEmptyState: Bool {
        document.text.isEmpty && document.segments.isEmpty && state == .idle && !editorFocused
    }

    /// The Reorganize button can be pressed: structuring and the endpoint are available, there are notes, and no
    /// reorganize is running and the recording is not finishing.
    public var canReorganize: Bool {
        if case .unavailable = reorganizeStatus { return false }
        return !isReorganizing && !isBusy && !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The server has structuring but no reorganize endpoint: the button is hidden and the toggle explains why.
    public var reorganizeHidden: Bool { reorganizeStatus == .unavailable(.unsupported) && !structuring.isOff }

    /// The "Auto-reorganize" toggle can be flipped (it shows off otherwise).
    public var autoReorganizeAvailable: Bool { !structuring.isOff && !reorganizeHidden }

    /// The small line under the editor about the last reorganize.
    public var reorganizeNote: String? {
        switch reorganizeStatus {
        case .failed(let code): "Couldn’t organize (\(code)) — will retry"
        case .organized(let failed, let reason): failed == 0 ? NotesStatus.organized : NotesStatus.organizeFailed(failed, reason: reason)
        case .conflict: "Notes changed while organizing — try again"
        case .tooLong: "Too long to organize — split the last section with a heading"
        default: nil
        }
    }

    /// The reorganize note reports a finished Organize with nothing left behind.
    public var reorganizeNoteIsSuccess: Bool { reorganizeStatus == .organized(failed: 0, reason: nil) }

    /// "Organized · Undo" shows after a reorganize until the next edit or append, a click, or 20 s.
    public var showUndoChip: Bool {
        if case .applied(let at) = reorganizeStatus { return dismissedChip != at }
        return false
    }

    public func dismissUndoChip() {
        if case .applied(let at) = reorganizeStatus { dismissedChip = at }
    }

    /// Why the notes pane shows an explanation instead of notes; nil when structuring is available.
    public var explanation: String? {
        switch structuring {
        case .off(.disabled):
            "Structuring is off. Turn on “Structure notes” below to turn the transcript into headings, bullets and to-dos."
        case .off(.correctionOff):
            canManageModels
                ? "Structured notes need a correction model. Choose one in Models on this Mac, and the transcript is turned into notes as you talk."
                : "Structured notes need a correction model. Turn on clean-up on the server to get them; the transcript keeps working meanwhile."
        case .off(.unsupported):
            "Structured notes need a newer Chirp server. Update chirp-server; the transcript keeps working meanwhile."
        case .off(.waiting):
            "Waiting for the server… Notes are structured once Chirp knows where the structuring model runs; the transcript keeps working meanwhile."
        default: nil
        }
    }

    /// "Manage Local Models…" is offered next to the explanation.
    public var offersModels: Bool { structuring == .off(.correctionOff) && canManageModels }

    /// The small line under the notes after a failed append pass.
    public var retryNote: String? {
        if case .failed(let code) = structuring { return "Couldn’t update notes (\(code)) — will retry" }
        return nil
    }

    /// Structuring can run at all (the toggle is the only thing keeping it off).
    public var structuringAvailable: Bool { !structuring.isOff || structuring == .off(.disabled) }

    /// The "Hearing…" strip under the editor: what no pass has structured yet, then the live partials. Never part of
    /// the editable text.
    public var hearingText: String {
        let structured = structuring.isOff ? "" : document.unstructuredTail
        return [structured, document.livePartial].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What Copy Markdown copies: the notes, or the transcript when the Transcript tab is showing (and always the
    /// transcript when there are no notes).
    public var copyText: String {
        if tab == .transcript || document.notesBody.isEmpty {
            return document.exportMarkdown(includeNotes: false)
        }
        return document.exportMarkdown(includeTranscript: false)
    }

    /// What Save… writes: the notes with the transcript appendix (the transcript only without notes).
    public var saveText: String { document.exportMarkdown(includeTranscript: true) }

    /// The recorder's state, unless a start failed before the recorder ran: that error shows only while the recorder
    /// is idle, stopped or in error itself, never over Connecting/Listening/Finishing.
    public static func displayState(recorder: NotesRecorderState, startError: String?) -> NotesRecorderState {
        guard let startError, acceptsStartError(recorder) else { return recorder }
        return .error(startError)
    }

    /// A start error may be recorded only while the recorder is not starting, recording or finishing.
    public static func acceptsStartError(_ recorder: NotesRecorderState) -> Bool { !recorder.isActive }

    /// The words VoiceOver hears for a status change.
    public var announcement: String {
        isError ? statusText : statusText.isEmpty ? "" : "Notes: \(statusText)"
    }
}
