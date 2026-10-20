import AppKit
import ChirpCore
import ChirpUI
import SwiftUI
import UniformTypeIdentifiers

/// The Live Notes window. It is never restored, never an `NSDocument` and never autosaved: the notes reach disk only
/// through Save… to a path the user picks, and the pasteboard only through Copy Markdown.
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    private let notes: NotesController
    private var window: NSWindow?
    var onOpenModels: () -> Void = {}

    init(notes: NotesController) {
        self.notes = notes
        super.init()
        let model = notes.model
        model.onCopy = { [weak self] in self?.copy() }
        model.onSave = { [weak self] in _ = self?.save() }
        model.onNew = { [weak self] in self?.new() }
        notes.confirmSpeakerDownload = { [weak self] message, done in self?.confirmSpeakerDownload(message, done: done) }
        model.onManageModels = { [weak self] in self?.onOpenModels() }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the window. From the hotkey it comes forward without becoming key, so the app in use keeps focus.
    func show(focus: Bool = true) {
        let w = window ?? makeWindow()
        window = w
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
        w.center()
        return w
    }

    /// Chirp is a menu-bar app with no visible main menu; this hidden one gives the Notes editor the standard
    /// Undo/Redo, clipboard and Find key equivalents, plus Edit ▸ Organize Notes (⌥⌘R). Every item goes through the
    /// responder chain, so it only acts while the Notes editor (or another text field) is first responder.
    static func installEditMenu() {
        guard NSApp.mainMenu?.item(withTitle: "Edit") == nil else { return }
        let main = NSApp.mainMenu ?? NSMenu()
        if main.items.isEmpty { main.addItem(NSMenuItem(title: "Chirp", action: nil, keyEquivalent: "")) }
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
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: closing and the dirty guard

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // While recording, closing only hides the window; the menu icon keeps showing the open microphone.
        if notes.isActive { sender.orderOut(nil); return false }
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
        guard notes.model.document.isDirty else { done(true); return }
        let alert = NSAlert()
        alert.messageText = "Save your notes?"
        alert.informativeText = "Notes are kept only in memory. If you don’t save them, they’re gone."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: done(self?.save() ?? false)
            case .alertSecondButtonReturn: done(true)
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

    // MARK: actions

    private func new() {
        guard !notes.isActive else { return }
        confirmDiscard(in: window) { [weak self] ok in if ok { self?.notes.reset() } }
    }

    private func copy() {
        let text = notes.model.copyText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        chirpLog.info("notes copy chars=\(text.count, privacy: .public)")
    }

    /// Save…: the notes and the transcript to a `.md` the user picks. Returns whether it was written.
    @discardableResult
    func save() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = notes.model.document.suggestedFileName()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let text = notes.model.saveText
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return false
        }
        notes.markSaved()
        chirpLog.info("notes saved chars=\(text.count, privacy: .public)")
        return true
    }
}
