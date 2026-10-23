import ChirpCore
import Foundation

/// The words of a voice edit (#97) in the Notes window.
extension NotesStatus {
    public static let voiceEditHelp = "Edit notes by voice (⇧⌘E): say what to change, then press again"
    public static let voiceEditDoneHelp = "Finish the spoken edit (⇧⌘E) — Esc cancels"
    public static let voiceEditListening = "Say the edit… (Esc cancels)"
    public static let voiceEditRunning = "Editing notes…"
    public static let edited = "Edited"
    public static let voiceEdited = "Notes edited"

    /// The note under the editor for an edit that did not apply; nil for one that did.
    public static func voiceEditNote(_ outcome: NotesEditOutcome) -> String? {
        switch outcome {
        case .applied: nil
        case .unchanged: "The edit changed nothing"
        case .refused("adds_content"): "Can’t add new content by voice — ask to remove, move, tidy or reword"
        case .refused("not_an_edit"): "That didn’t sound like an edit to the notes"
        case .refused: "Couldn’t tell what to change — try naming the section"
        case .conflict: "Notes changed while editing — try again"
        case .nothing("not_heard"): "Didn’t catch an edit — try again"
        case .nothing("too_long"): "Too much to edit at once — select a section first"
        case .nothing: "Nothing to edit yet"
        case .failed(let code): "Couldn’t edit notes (\(code))"
        }
    }
}

extension NotesModel {
    /// The header's status while a voice edit listens or runs; nil otherwise.
    public var voiceEditStatusText: String? {
        switch voiceEdit {
        case .listening(let heard): heard.isEmpty ? NotesStatus.voiceEditListening : "“\(heard)”"
        case .editing: NotesStatus.voiceEditRunning
        default: nil
        }
    }

    /// The note for the last edit that did not apply.
    public var voiceEditNote: String? {
        if case .done(let outcome, _) = voiceEdit { return NotesStatus.voiceEditNote(outcome) }
        return nil
    }

    /// "Edited · Undo" after a voice edit applied, until dismissed (a click, 20 s, the next edit).
    public var showEditedChip: Bool {
        if case .done(.applied, _) = voiceEdit { return true }
        return false
    }

    public var isVoiceEditing: Bool { voiceEdit.isBusy }
}
