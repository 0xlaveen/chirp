import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Pause/Resume and Restore Notes Before Organize through the real `NotesSession` (the window's buttons, ⌃⌥N, the menu
/// switch), and the Notes menu's model (#65).
@MainActor
@Suite(.serialized) struct NotesPauseSessionTests {
    @Test func pauseClosesTheMicrophoneStopsTheClockAndResumeContinuesTheSameNotes() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(3)
        await h.session.pause()
        await h.settle()
        #expect(h.recorder.state == .paused && !h.engine.isTapped && !h.session.isCapturing)
        #expect(h.model.statusText.hasPrefix("Paused · 00:0"))
        #expect(h.edges.tick == nil)
        #expect(h.edges.sounds == [.start, .stop])
        let elapsed = h.recorder.elapsed
        let stamp = h.document.startedAt
        await h.resumeForTest()
        #expect(h.recorder.state == .recording && h.engine.isTapped)
        h.expectStatus(NotesStatus.listening)
        await h.speak(2)
        #expect(h.recorder.elapsed > elapsed && h.document.startedAt == stamp)
        await h.stop()
        #expect(h.recorder.state == .stopped)
        #expect(h.streams.bytesBySocket.keys.sorted() == [0, 1])
        #expect(h.edges.sounds == [.start, .stop, .start, .stop])
    }

    @Test func theNotesHotkeyResumesAPausedSessionAndStopsARecordingOne() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(2)
        await h.session.pause(reason: "Paused while the Mac slept")
        #expect(h.model.statusText.hasPrefix("Paused while the Mac slept"))
        h.session.toggle(fromHotkey: true)
        await h.until("resumed") { h.recorder.state == .recording && h.engine.isTapped }
        h.session.toggle(fromHotkey: true)
        await h.until("stopped") { h.recorder.state == .stopped }
    }

    @Test func theRecordButtonStopsAPausedSession() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(2)
        await h.session.pause()
        h.model.onRecordToggle()
        await h.until("stopped") { h.recorder.state == .stopped }
        #expect(h.transcript == ["Segment 0."])
    }

    @Test func pausingChirpWhilePausedDoesAFullStop() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(2)
        await h.session.pause()
        h.session.setRunning(false)
        await h.until("stopped") { h.recorder.state == .stopped }
    }

    @Test func aPausedSessionKeepsTheDocumentAndNewIsRefused() async {
        let h = NotesHarness()
        await h.record()
        await h.speak(2)
        await h.session.pause()
        await h.until("segment committed") { !h.document.segments.isEmpty }
        #expect(h.session.isActive)
        h.session.reset()
        #expect(h.recorder.state == .paused && !h.document.segments.isEmpty)
        await h.stop()
    }

    @Test func restoreBringsBackTheTextBeforeOrganizeAsOneUndoStep() async {
        let h = NotesHarness()
        await h.typeAtEnd("## Plan\n- ship it\n- test it")
        let after = h.text
        let before = "- test it\n- ship it"
        var snapshots = NotesSnapshots()
        snapshots.record([NotesDocument.diff(before, after, kind: .reorganize)!], from: before, result: after, at: Date())
        h.model.snapshots = snapshots
        let id = snapshots.latest!.id
        #expect(h.model.canRestore)
        h.model.review()
        #expect(h.model.reviewing == id)
        h.model.onRestoreSnapshot(id, false)
        await h.settle()
        #expect(h.text == before && h.document.text == before)
        #expect(h.model.reviewing == nil && h.model.snapshots.items.isEmpty)
        h.expectEditorInSync()
        await h.undo()
        #expect(h.text == after && h.document.text == after)
    }

    @Test func restoreKeepsWhatWasTypedAfterOrganizeOrAsksFirst() async {
        let h = NotesHarness()
        await h.typeAtEnd("alpha\ngamma\nbeta\nend")
        let after = h.text
        let before = "alpha\nbeta\ngamma\nend"
        var snapshots = NotesSnapshots()
        snapshots.record([NotesDocument.diff(before, after, kind: .reorganize)!], from: before, result: after, at: Date())
        h.model.snapshots = snapshots
        let id = snapshots.latest!.id
        await h.typeAtEnd("\nmine")
        h.model.onRestoreSnapshot(id, false)
        await h.settle()
        #expect(h.text == before + "\nmine")

        // Typing among the lines Organize moved cannot be re-applied: it asks, and only replaces on confirmation.
        let h2 = NotesHarness()
        await h2.typeAtEnd("alpha\ngamma\nbeta\nend")
        var s2 = NotesSnapshots()
        s2.record([NotesDocument.diff(before, h2.text, kind: .reorganize)!], from: before, result: h2.text, at: Date())
        h2.model.snapshots = s2
        let id2 = s2.latest!.id
        h2.editor.textView.insertText("X", replacementRange: NSRange(location: 9, length: 0))
        await h2.settle()
        let typed = h2.text
        h2.model.onRestoreSnapshot(id2, false)
        #expect(h2.model.confirmingRestore == id2 && h2.text == typed)
        h2.model.onRestoreSnapshot(id2, true)
        await h2.settle()
        #expect(h2.text == before && h2.model.confirmingRestore == nil)
    }

    @Test func newDropsTheSnapshots() async {
        let h = NotesHarness()
        await h.typeAtEnd("one two")
        h.model.snapshots.record([NotesDocument.diff("x", "one two", kind: .reorganize)!], from: "x", result: "one two", at: Date())
        #expect(!h.model.snapshots.items.isEmpty)
        h.session.reset()
        #expect(h.model.snapshots.items.isEmpty)
    }

    // MARK: the Notes menu

    @Test func theMenuHasTheListedShortcutsAndIsDisabledWhenTheWindowIsNotKey() {
        let model = NotesModel()
        model.document = Snapshots.demoNotes()
        model.state = .recording
        model.snapshots = Snapshots.demoSnapshots()
        let library = NotesLibraryModel()
        let keys = NotesCommand.items(for: model, library: library, windowIsKey: true)
        func row(_ c: NotesCommand) -> NotesCommand.Item { keys.first { $0.command == c }! }
        let cmd: NSEvent.ModifierFlags = .command, shiftCmd: NSEvent.ModifierFlags = [.command, .shift]
        let optCmd: NSEvent.ModifierFlags = [.command, .option]
        #expect((row(.newNote).key, row(.newNote).modifiers) == ("n", cmd))
        #expect((row(.record).key, row(.record).modifiers) == ("r", shiftCmd))
        #expect((row(.pause).key, row(.pause).modifiers) == ("p", shiftCmd))
        #expect((row(.toggleInspector).key, row(.toggleInspector).modifiers) == ("t", optCmd))
        #expect((row(.findNotes).key, row(.findNotes).modifiers) == ("f", optCmd))
        #expect((row(.copyMarkdown).key, row(.copyMarkdown).modifiers) == ("c", shiftCmd))
        // ⌘S is not a Save step any more: Export is ⇧⌘S, and ⇧⌘E stays Edit Notes by Voice.
        #expect((row(.export).key, row(.export).modifiers) == ("s", shiftCmd))
        #expect((row(.deleteNote).key, row(.deleteNote).modifiers) == (String(UnicodeScalar(NSBackspaceCharacter)!), cmd))
        #expect(row(.record).title == "Stop Recording" && row(.pause).title == "Pause Recording")
        #expect(row(.toggleInspector).title == "Show Transcript" && !row(.showMarkdown).checked)
        #expect(row(.restoreOrganize).enabled)
        #expect(NotesCommand.toggleInspector.menu == .view && NotesCommand.showMarkdown.menu == .view && NotesCommand.newNote.menu == .notes)
        // Every command is in the menu once.
        #expect(Set(keys.map(\.command)) == Set(NotesCommand.allCases) && keys.count == NotesCommand.allCases.count)

        let away = NotesCommand.items(for: model, library: library, windowIsKey: false)
        #expect(away.allSatisfy { !$0.enabled })
    }

    @Test func menuItemsFollowTheStateAndRunTheToolbarsActions() {
        let model = NotesModel()
        let library = NotesLibraryModel()
        var log: [String] = []
        model.onRecordToggle = { log.append("record") }
        model.onPauseToggle = { log.append("pause") }
        model.onCopy = { log.append("copy") }
        model.onSave = { log.append("save") }
        library.onNew = { log.append("new") }
        library.onInspector = { log.append("inspector \($0)") }
        library.onShowMarkdown = { log.append("markdown \($0)") }
        library.onFocusSearch = { log.append("search") }
        func item(_ c: NotesCommand) -> NotesCommand.Item { NotesCommand.items(for: model, library: library, windowIsKey: true).first { $0.command == c }! }
        #expect(!item(.pause).enabled && !item(.copyMarkdown).enabled && !item(.export).enabled && item(.newNote).enabled)
        #expect(item(.record).enabled && item(.record).title == "Start Recording" && !item(.restoreOrganize).enabled)
        model.state = .paused
        #expect(item(.pause).enabled && item(.pause).title == "Resume Recording" && item(.record).title == "Stop Recording")
        model.state = .stopping
        #expect(!item(.record).enabled)
        model.document = Snapshots.demoNotes()
        model.state = .stopped
        // A finished note continues.
        #expect(item(.record).title == NotesLibraryText.continueRecording)
        for c in [NotesCommand.record, .pause, .toggleInspector, .showMarkdown, .findNotes, .copyMarkdown, .export, .newNote] {
            model.perform(c, library: library)
        }
        #expect(log == ["record", "pause", "inspector true", "markdown true", "search", "copy", "save", "new"])
        #expect(item(.toggleInspector).title == "Hide Transcript" && item(.showMarkdown).checked)
    }

    @Test func recordOnANoteBesideARecordingContinuesThereAndDeleteSkipsTheRecordingNote() {
        let model = NotesModel()
        model.document = Snapshots.demoNotes()
        model.state = .recording
        let library = NotesLibraryModel()
        library.recordingID = model.document.id
        let other = NotesModel()
        other.document = NotesDocument(text: "## Other")
        other.state = .stopped
        library.browsed = other
        library.notes = [NotesLibraryEntry(id: other.document.id, title: "Other", createdAt: Date(), updatedAt: Date()),
                         NotesLibraryEntry(id: model.document.id, title: "Rec", createdAt: Date(), updatedAt: Date(), recording: true)]
        var continued: [UUID] = [], trashed: [UUID] = []
        library.onContinue = { continued.append($0) }
        library.onTrash = { trashed.append($0) }
        model.onRecordToggle = { Issue.record("the recording must not stop") }
        func item(_ c: NotesCommand) -> NotesCommand.Item { NotesCommand.items(for: model, library: library, windowIsKey: true).first { $0.command == c }! }
        #expect(item(.record).title == "Continue Recording Here…")
        model.perform(.record, library: library)
        #expect(continued == [other.document.id])
        library.selection = .note(model.document.id)
        #expect(!item(.deleteNote).enabled)                       // a recording note can't be deleted
        model.perform(.deleteNote, library: library)
        library.selection = .note(other.document.id)
        #expect(item(.deleteNote).enabled)
        model.perform(.deleteNote, library: library)
        #expect(trashed == [other.document.id])
    }
}
