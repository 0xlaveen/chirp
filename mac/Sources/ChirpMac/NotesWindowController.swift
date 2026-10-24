import AppKit
import ChirpCore
import ChirpUI
import SwiftUI
import UniformTypeIdentifiers

/// The Live Notes window. Notes save continuously to the local library. Markdown export is separate and may be
/// kept up to date at a user-chosen path. Window restoration stores geometry only.
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    private let notes: NotesController
    private var window: NSWindow?
    var onOpenModels: () -> Void = {}
    /// Where the window is in the Dock's eyes: on screen (or minimised), hidden while Notes records, or gone.
    var dock: DockController?
    private enum Presence { case closed, shown, hidden }
    private var presence = Presence.closed
    static let frameName = "ChirpNotes"

    init(notes: NotesController) {
        self.notes = notes
        super.init()
        let model = notes.model
        model.onCopy = { [weak self] in self?.copy() }
        model.onSave = { [weak self] in _ = self?.save() }
        model.onNew = { [weak self] in self?.new() }
        model.onRecoveryKeep = { [weak self] in self?.keepRecovered() }
        model.onRecoverySave = { [weak self] in self?.saveRecovered() }
        model.onRecoveryDiscard = { [weak self] in self?.notes.dropRecovered() }
        notes.confirmSpeakerDownload = { [weak self] message, done in self?.confirmSpeakerDownload(message, done: done) }
        notes.confirmRememberVoice = { [weak self] name, done in self?.confirmRememberVoice(name, done: done) }
        model.onManageModels = { [weak self] in self?.onOpenModels() }
        NotesMenuTarget.shared.model = model
        NotesMenuTarget.shared.windowIsKey = { [weak self] in NSApp.isActive && self?.window?.isKeyWindow == true }
    }

    var isVisible: Bool { window?.isVisible ?? false }
    /// Chirp is the active app and the Notes window is its key window: the dictation hotkey drives Notes.
    var isFrontmost: Bool { NSApp.isActive && window?.isKeyWindow == true }

    /// Shows the window. From the hotkey it comes forward without becoming key, so the app in use keeps focus.
    func show(focus: Bool = true) {
        let w = window ?? makeWindow()
        window = w
        setPresence(.shown)
        notes.model.dictationKey = settings.hotkey.title
        notes.model.notesKey = settings.notesHotkey.title
        if focus {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            notes.model.focusRequest += 1   // the editor takes the keyboard
        } else {
            w.orderFront(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        Self.installEditMenu()
        let size = NotesViewMetrics.defaultSize
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Chirp Notes"
        w.contentView = NSHostingView(rootView: NotesView(model: notes.model))
        w.contentMinSize = NotesViewMetrics.minimumSize
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.tabbingMode = .disallowed
        w.delegate = self
        // Size and position only, never content; a first run centres it.
        if !w.setFrameUsingName(Self.frameName) { w.center() }
        w.setFrameAutosaveName(Self.frameName)
        return w
    }

    private func setPresence(_ next: Presence) {
        guard next != presence else { return }
        let before = presence
        presence = next
        dock?.update { dock in
            switch (before, next) {
            case (.closed, .shown), (.hidden, .shown): dock.windowShown()
            case (.shown, .hidden): dock.windowHidden()
            case (.shown, .closed): dock.windowClosed()
            case (.hidden, .closed): dock.windowClosed(wasHidden: true)
            default: break
            }
        }
    }

    /// New Notes from the Dock menu: the window, then the usual keep-or-discard question.
    func newNotes() {
        show()
        new()
    }

    func windowWillClose(_ notification: Notification) { setPresence(.closed) }

    /// The app menu's About and Settings…, which the delegate wires (the menu is only seen while Chirp is in the Dock).
    static var onAbout: () -> Void = {}
    static var onSettings: () -> Void = {}
    @objc private static func about() { onAbout() }
    @objc private static func settingsItem() { onSettings() }

    /// The main menu, seen only while Chirp is in the Dock (a Notes window is open): Chirp (About, Settings…, Hide,
    /// Quit), Edit and Window (which lists the Notes window). Edit gives the Notes editor the standard Undo/Redo,
    /// clipboard and Find key equivalents, plus Organize Notes (⌥⌘R) and Restore Notes Before Organize…; Notes holds the
    /// window's own shortcuts (`NotesMenuTarget`). Every Edit item goes through the responder chain,
    /// so it only acts while the Notes editor (or another text field) is first responder.
    static func installEditMenu() {
        guard NSApp.mainMenu?.item(withTitle: "Edit") == nil else { return }
        let main = NSApp.mainMenu ?? NSMenu()
        if main.items.isEmpty { main.addItem(appMenuItem()) }
        let edit = NSMenu(title: "Edit")
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = tag
            menu.addItem(item)
        }
        add(edit, "Undo", NSSelectorFromString("undo:"), "z")
        add(edit, "Redo", NSSelectorFromString("redo:"), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        let finder = #selector(NSTextView.performTextFinderAction(_:))
        add(find, "Find…", finder, "f", tag: NSTextFinder.Action.showFindInterface.rawValue)
        add(find, "Find Next", finder, "g", tag: NSTextFinder.Action.nextMatch.rawValue)
        add(find, "Find Previous", finder, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue)
        add(find, "Use Selection for Find", finder, "e", tag: NSTextFinder.Action.setSearchString.rawValue)
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        edit.addItem(findItem)
        edit.addItem(.separator())
        add(edit, "Organize Notes", NSSelectorFromString("reorganizeNotes:"), "r", [.command, .option])
        add(edit, "Edit Notes by Voice", NSSelectorFromString("editNotesByVoice:"), "e", [.command, .shift])
        edit.addItem(NotesMenuTarget.shared.restoreItem())
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        main.addItem(NotesMenuTarget.shared.menuItem())
        main.addItem(windowMenuItem())
        NSApp.mainMenu = main
    }

    private static func appMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Chirp")
        func add(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            menu.addItem(item)
        }
        add("About Chirp", #selector(about), target: self)
        menu.addItem(.separator())
        add("Settings…", #selector(settingsItem), ",", target: self)
        menu.addItem(.separator())
        add("Hide Chirp", #selector(NSApplication.hide(_:)), "h")
        add("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add("Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add("Quit Chirp", #selector(NSApplication.terminate(_:)), "q")
        let item = NSMenuItem(title: "Chirp", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// AppKit lists the open windows at the bottom of the menu `NSApp.windowsMenu` points to.
    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        menu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        menu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    // MARK: closing and the dirty guard

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // While recording, closing only hides the window; the menu icon keeps showing the open microphone.
        if notes.isActive { sender.orderOut(nil); setPresence(.hidden); return false }
        notes.journal.flush()
        if notes.library != nil { return true }
        guard notes.model.document.isDirty else { return true }
        confirmDiscard(in: sender) { [weak self] discard in
            guard discard else { return }
            self?.notes.reset()
            sender.close()
        }
        return false
    }

    /// Save… / Discard / Cancel for a dirty document. `done(true)` means it is safe to drop the document (saved or
    /// discarded). As a sheet on `window` when it is visible, else app-modal (quit with the window closed).
    func confirmDiscard(in window: NSWindow? = nil, done: @escaping (Bool) -> Void) {
        if notes.library != nil { notes.journal.flush(); done(true); return }
        guard notes.model.document.isDirty else { done(true); return }
        let alert = NSAlert()
        alert.messageText = "Save your notes?"
        alert.informativeText = "These notes are not saved yet. If you discard them, they’re gone."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: done(self?.save() ?? false)
            case .alertSecondButtonReturn:
                self?.notes.discardJournal()
                done(true)
            default: done(false)
            }
        }
        NSApp.activate()
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// The one-time speaker model download asks first: nothing downloads without "Download".
    private func confirmSpeakerDownload(_ message: String, done: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Download the speaker model?"
        alert.informativeText = message
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { done($0 == .alertFirstButtonReturn) }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// "Remember this voice as Maya…": Remember is enabled only once the consent box is ticked.
    private func confirmRememberVoice(_ name: String, done: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = VoiceText.consentTitle
        alert.informativeText = VoiceText.consentDetail(name)
        alert.addButton(withTitle: "Remember")
        alert.addButton(withTitle: "Cancel")
        let tick = ConsentBox(title: VoiceText.consentTick, remember: alert.buttons[0])
        alert.accessoryView = tick
        let handle: (NSApplication.ModalResponse) -> Void = { done($0 == .alertFirstButtonReturn && tick.state == .on) }
        if let window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    // MARK: actions

    private func new() {
        guard !notes.isActive else { return }
        confirmDiscard(in: window) { [weak self] ok in if ok { self?.notes.reset() } }
    }

    /// Keep: after the usual question about the notes on screen, the recovered session replaces them.
    private func keepRecovered() {
        confirmDiscard(in: window) { [weak self] ok in if ok { self?.notes.keepRecovered() } }
    }

    /// Save… for the recovered session: it is written without being loaded, then its journal goes.
    private func saveRecovered() {
        guard let document = notes.offeredDocument,
              let (url, _) = choosePath(name: document.suggestedFileName(), offerKeeping: false) else { return }
        guard write(document.exportMarkdown(includeTranscript: true), to: url) else { return }
        notes.dropRecovered()
    }

    private func copy() {
        let text = notes.model.copyText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        chirpLog.info("notes copy chars=\(text.count, privacy: .public)")
    }

    /// The save panel: a `.md` path, and (for the open document) the check box that keeps the file up to date.
    private func choosePath(name: String, offerKeeping: Bool) -> (URL, keep: Bool)? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let last = notes.journal.savedFile { panel.directoryURL = last.deletingLastPathComponent() }
        else if let folder = settings.notesExportFolder { panel.directoryURL = URL(fileURLWithPath: folder) }
        let keep = NSButton(checkboxWithTitle: NotesStatus.keepSavingCheckbox, target: nil, action: nil)
        if offerKeeping {
            keep.state = notes.journal.keepStatus.isSaving ? .on : .off
            keep.setFrameSize(keep.fittingSize)
            panel.accessoryView = keep
        }
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, keep.state == .on)
    }

    private func write(_ text: String, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Save…: the notes and the transcript to a `.md` the user picks. Returns whether it was written.
    @discardableResult
    func save() -> Bool {
        guard let (url, keep) = choosePath(name: notes.model.document.suggestedFileName(), offerKeeping: true) else { return false }
        let text = notes.model.saveText
        guard write(text, to: url) else { return false }
        notes.didSave(to: url, keep: keep)
        chirpLog.info("notes saved chars=\(text.count, privacy: .public)")
        return true
    }
}

/// The consent tick of "Remember this voice": the Remember button follows it.
private final class ConsentBox: NSButton {
    private weak var remember: NSButton?

    init(title: String, remember: NSButton) {
        self.remember = remember
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        state = .off
        remember.isEnabled = false
        target = self
        action = #selector(toggled)
        sizeToFit()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func toggled() { remember?.isEnabled = state == .on }
}
