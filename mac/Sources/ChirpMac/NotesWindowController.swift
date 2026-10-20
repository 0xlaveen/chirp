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
        } else {
            w.orderFront(nil)
        }
    }

    private func makeWindow() -> NSWindow {
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
