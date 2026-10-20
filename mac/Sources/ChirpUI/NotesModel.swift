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
    public static let stopped = "Stopped"
    public static let empty = "Press Record or \(MenuContent.notesHotkeyTitle) to start taking notes."
    public static let privacy = "Notes stay in memory until you save them."
    public static let speakerLabels = "Label speakers"
    public static let speakerHelp = "Labels who is talking as Person 1, Person 2… On this Mac only: voices, labels and audio never leave it. Up to 4 people; a 5th voice joins the closest one."
    public static func speakerDownloadPrompt(size: String) -> String {
        "Speaker labels need a \(size) on-device model, downloaded once. Audio never leaves this Mac."
    }
}

/// The on-device speaker model, as the Notes window shows it.
public enum SpeakerModelState: Equatable, Sendable {
    case notDownloaded
    /// 0…1.
    case downloading(Double)
    case loading
    case ready
    case failed(String)

    public var isFailure: Bool { if case .failed = self { true } else { false } }
    public var isDownloading: Bool { if case .downloading = self { true } else { false } }
}

/// One transcript row: a whole segment (no labels, or a gap), or one speaker turn of a labelled segment.
public struct TranscriptRow: Identifiable, Equatable {
    public var id: String
    public var offset: TimeInterval
    public var segment: NotesSegment
    public var turn: SpeakerTurn?
    /// The speaker chip's name and colour slot; nil when the chip collapses (same person as the row before).
    public var chip: (name: String, color: Int, approximate: Bool)?

    public static func == (a: TranscriptRow, b: TranscriptRow) -> Bool {
        a.id == b.id && a.offset == b.offset && a.segment == b.segment && a.turn == b.turn
            && a.chip?.name == b.chip?.name && a.chip?.color == b.chip?.color && a.chip?.approximate == b.chip?.approximate
    }
}

/// What the Notes window shows: a mirror of `NotesRecorder` plus the window's own choices. In memory only; the
/// controller stores just the two preferences (the tab and the "Structure notes" toggle).
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
    /// The user's "Label speakers" toggle, and the model behind it.
    public var speakerLabels = false
    public var speakerModel: SpeakerModelState = .notDownloaded

    public var onRecordToggle: () -> Void = {}
    public var onCopy: () -> Void = {}
    public var onSave: () -> Void = {}
    public var onNew: () -> Void = {}
    public var onManageModels: () -> Void = {}
    public var onStructureToggle: (Bool) -> Void = { _ in }
    public var onTabChange: (NotesTab) -> Void = { _ in }
    public var onSpeakerLabelsToggle: (Bool) -> Void = { _ in }

    public init() {}

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
        case .recording: structuring == .running ? NotesStatus.updating : NotesStatus.listening
        case .stopping: NotesStatus.finishing
        case .stopped: NotesStatus.stopped
        case .error(let message): message
        }
    }

    /// A pass is running on the open block.
    public var isUpdating: Bool { structuring == .running }

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

    /// The small line under the notes after a failed pass.
    public var retryNote: String? {
        if case .failed(let code) = structuring { return "Couldn’t update notes (\(code)) — will retry" }
        return nil
    }

    /// Structuring can run at all (the toggle is the only thing keeping it off).
    public var structuringAvailable: Bool { !structuring.isOff || structuring == .off(.disabled) }

    /// The notes pane's grey tail: what no pass has structured yet, then the live partials.
    public var liveTail: String {
        let structured = structuring.isOff ? "" : document.unstructuredTail
        return [structured, document.livePartial].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What Copy Markdown copies: the notes, or the transcript when the Transcript tab is showing (and always the
    /// transcript when there are no notes).
    public var copyText: String {
        if tab == .transcript || !structuringAvailable || document.notesBody.isEmpty {
            return document.exportMarkdown(includeTranscript: true, structuring: false)
        }
        return document.exportMarkdown(includeTranscript: false)
    }

    /// What Save… writes: the notes with the transcript appendix (the transcript only without notes).
    public var saveText: String { document.exportMarkdown(includeTranscript: true, structuring: structuringAvailable) }

    /// The recorder's state, unless a start failed before the recorder ran: that error shows only while the recorder
    /// is idle, stopped or in error itself, never over Connecting/Listening/Finishing.
    public static func displayState(recorder: NotesRecorderState, startError: String?) -> NotesRecorderState {
        guard let startError, acceptsStartError(recorder) else { return recorder }
        return .error(startError)
    }

    /// A start error may be recorded only while the recorder is not starting, recording or finishing.
    public static func acceptsStartError(_ recorder: NotesRecorderState) -> Bool { !recorder.isActive }

    // MARK: speakers

    /// The footer's speaker line: the download, or how many people were heard.
    public var speakerStatus: String? {
        switch speakerModel {
        case .downloading(let f): return "Downloading speaker model… \(Int((f * 100).rounded()))%"
        case .loading: return speakerLabels ? "Loading speaker model…" : nil
        case .failed(let message): return "Speaker labels unavailable: \(message)"
        case .notDownloaded, .ready:
            guard speakerLabels else { return nil }
            let n = document.speakerCount
            return n == 0 ? nil : n == 1 ? "1 speaker" : "\(n) speakers"
        }
    }

    /// A chip reappears for the same person after this long.
    public static let chipRepeat: TimeInterval = 60

    /// The transcript's rows: a labelled segment gives one row per turn, and consecutive turns by one person (across
    /// segments too) collapse the chip until a minute has passed.
    public var transcriptRows: [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var last: (person: Int, at: TimeInterval)?
        let roster = document.roster
        for s in document.segments {
            guard let turns = s.turns, !turns.isEmpty, !s.isGap else {
                rows.append(TranscriptRow(id: "\(s.id)", offset: s.offset, segment: s))
                last = nil
                continue
            }
            for (i, t) in turns.enumerated() {
                let person = roster.resolve(t.person)
                let same = last.map { $0.person == person && t.start - $0.at < Self.chipRepeat } ?? false
                if !same { last = (person, t.start) }
                rows.append(TranscriptRow(id: "\(s.id).\(i)", offset: t.start, segment: s, turn: t,
                                          chip: same ? nil : (roster.displayName(person), roster.colorIndex(person), t.approximate)))
            }
        }
        return rows
    }

    /// The words VoiceOver hears for a status change.
    public var announcement: String {
        isError ? statusText : statusText.isEmpty ? "" : "Notes: \(statusText)"
    }
}
