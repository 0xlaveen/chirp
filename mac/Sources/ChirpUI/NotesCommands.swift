import AppKit
import ChirpCore

/// The Notes window's own shortcuts. They live in the main menu (so Help search finds them) and work only while the
/// Notes window is key; this is the list the menu is built from and the tests check.
public enum NotesCommand: CaseIterable, Sendable {
    case record, pause, showNotes, showTranscript, showSplit, togglePreview, copyMarkdown, save, new
    case restoreOrganize

    public struct Item: Equatable, Sendable {
        public var command: NotesCommand
        public var title: String
        public var key: String
        public var modifiers: NSEvent.ModifierFlags
        public var enabled: Bool
        /// A check mark: the layout or view that is showing.
        public var checked: Bool
    }

    static let shiftCommand: NSEvent.ModifierFlags = [.command, .shift]

    /// The menu rows for `model`. Everything is disabled unless `windowIsKey`.
    @MainActor
    public static func items(for model: NotesModel, windowIsKey: Bool) -> [Item] {
        allCases.map { c in
            let on = windowIsKey
            switch c {
            case .record:
                return Item(command: c, title: model.state.isActive ? "Stop Recording" : "Start Recording", key: "r", modifiers: shiftCommand,
                            enabled: on && model.canToggle, checked: false)
            case .pause:
                return Item(command: c, title: model.isPaused ? "Resume Recording" : "Pause Recording", key: "p", modifiers: shiftCommand,
                            enabled: on && (model.isPaused || model.state == .recording), checked: false)
            case .showNotes: return Item(command: c, title: "Notes", key: "1", modifiers: .command, enabled: on, checked: model.tab == .notes)
            case .showTranscript:
                return Item(command: c, title: "Transcript", key: "2", modifiers: .command, enabled: on, checked: model.tab == .transcript)
            case .showSplit: return Item(command: c, title: "Split", key: "3", modifiers: .command, enabled: on, checked: model.tab == .split)
            case .togglePreview:
                return Item(command: c, title: model.preview ? "Edit Notes" : "Preview Notes", key: "e", modifiers: [.command, .option],
                            enabled: on && model.tab != .transcript, checked: false)
            case .copyMarkdown:
                return Item(command: c, title: "Copy Markdown", key: "c", modifiers: shiftCommand, enabled: on && model.canExport, checked: false)
            case .save: return Item(command: c, title: "Save…", key: "s", modifiers: .command, enabled: on && model.canExport, checked: false)
            case .new: return Item(command: c, title: "New", key: "n", modifiers: .command, enabled: on && model.canNew, checked: false)
            case .restoreOrganize:
                return Item(command: c, title: "Restore Notes Before Organize…", key: "", modifiers: [], enabled: on && model.canRestore, checked: false)
            }
        }
    }
}

extension NotesModel {
    /// Runs a menu command (the same actions as the header's buttons).
    public func perform(_ command: NotesCommand) {
        switch command {
        case .record: onRecordToggle()
        case .pause: onPauseToggle()
        case .showNotes: select(.notes)
        case .showTranscript: select(.transcript)
        case .showSplit: select(.split)
        case .togglePreview:
            preview.toggle()
            onPreviewToggle(preview)
        case .copyMarkdown: onCopy()
        case .save: onSave()
        case .new: onNew()
        case .restoreOrganize: review()
        }
    }

    public func select(_ next: NotesTab) {
        tab = next
        onTabChange(next)
    }
}
