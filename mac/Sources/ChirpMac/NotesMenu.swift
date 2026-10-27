import AppKit
import ChirpUI

/// The Notes and View menus in the (usually hidden) main menu: New Note, Record/Continue, Pause, Rename, Delete,
/// Search, Copy Markdown and Export Markdown…; the transcript inspector and Show Markdown. Their shortcuts work and
/// Help search finds them. Every item is disabled unless the Notes window is key (`NotesCommand.items`), so the
/// shortcuts never fire from Settings or another app's window.
@MainActor
final class NotesMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = NotesMenuTarget()
    var model: NotesModel?
    var library: NotesLibraryModel?
    var windowIsKey: () -> Bool = { false }
    /// A text field or the editor has the keyboard: ⌘⌫ is theirs (delete to the start of the line), not Delete Note.
    var textHasFocus: () -> Bool = { false }

    private var commands: [NotesCommand] { NotesCommand.allCases }

    /// The "Notes" menu item.
    func menuItem() -> NSMenuItem {
        submenu("Notes", .notes, separatorsBefore: [.record, .renameNote, .findNotes, .copyMarkdown])
    }

    /// The "View" menu item.
    func viewItem() -> NSMenuItem { submenu("View", .view, separatorsBefore: []) }

    private func submenu(_ title: String, _ which: NotesCommand.Menu, separatorsBefore: Set<NotesCommand>) -> NSMenuItem {
        let menu = NSMenu(title: title)
        for (i, c) in commands.enumerated() where c.menu == which {
            if separatorsBefore.contains(c), !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(item(for: c, tag: i))
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    func restoreItem() -> NSMenuItem { item(for: .restoreOrganize, tag: commands.firstIndex(of: .restoreOrganize) ?? 0) }

    private func item(for command: NotesCommand, tag: Int) -> NSMenuItem {
        let shown = NotesCommand.items(for: model ?? NotesModel(), library: library, windowIsKey: false).first { $0.command == command }
        let item = NSMenuItem(title: shown?.title ?? "", action: #selector(run(_:)), keyEquivalent: shown?.key ?? "")
        item.keyEquivalentModifierMask = shown?.modifiers ?? []
        item.tag = tag
        item.target = self
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard commands.indices.contains(sender.tag), let model else { return }
        model.perform(commands[sender.tag], library: library)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard commands.indices.contains(menuItem.tag), let model else { return false }
        let row = NotesCommand.items(for: model, library: library, windowIsKey: windowIsKey())[menuItem.tag]
        menuItem.title = row.title
        menuItem.state = row.checked ? .on : .off
        menuItem.isHidden = row.hidden
        return row.enabled && !(row.command == .deleteNote && textHasFocus())
    }
}
