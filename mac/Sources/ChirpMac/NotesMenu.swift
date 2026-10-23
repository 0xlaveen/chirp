import AppKit
import ChirpUI

/// The Notes menu in the (usually hidden) main menu: Record/Stop, Pause/Resume, the layouts, Edit/Preview, Copy
/// Markdown, Save… and New, so their shortcuts work and Help search finds them. Every item is disabled unless the Notes
/// window is key (`NotesCommand.items`), so the shortcuts never fire from Settings or another app's window.
@MainActor
final class NotesMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = NotesMenuTarget()
    var model: NotesModel?
    var windowIsKey: () -> Bool = { false }

    private var commands: [NotesCommand] { NotesCommand.allCases }

    /// The "Notes" menu item, and the Restore row for the Edit menu.
    func menuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Notes")
        for (i, c) in commands.enumerated() where c != .restoreOrganize {
            if c == .showNotes || c == .togglePreview { menu.addItem(.separator()) }
            menu.addItem(item(for: c, tag: i))
        }
        let item = NSMenuItem(title: "Notes", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    func restoreItem() -> NSMenuItem { item(for: .restoreOrganize, tag: commands.firstIndex(of: .restoreOrganize) ?? 0) }

    private func item(for command: NotesCommand, tag: Int) -> NSMenuItem {
        let shown = NotesCommand.items(for: model ?? NotesModel(), windowIsKey: false).first { $0.command == command }
        let item = NSMenuItem(title: shown?.title ?? "", action: #selector(run(_:)), keyEquivalent: shown?.key ?? "")
        item.keyEquivalentModifierMask = shown?.modifiers ?? []
        item.tag = tag
        item.target = self
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard commands.indices.contains(sender.tag), let model else { return }
        model.perform(commands[sender.tag])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard commands.indices.contains(menuItem.tag), let model else { return false }
        let row = NotesCommand.items(for: model, windowIsKey: windowIsKey())[menuItem.tag]
        menuItem.title = row.title
        menuItem.state = row.checked ? .on : .off
        return row.enabled
    }
}
