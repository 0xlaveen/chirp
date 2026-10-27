import AppKit
import SwiftUI
import Testing
@testable import ChirpCore
@testable import ChirpUI

@MainActor @Suite(.serialized) struct NotesModernUXTests {
    private func settle(_ window: NSWindow) {
        for _ in 0..<4 { window.layoutIfNeeded(); window.contentView?.superview?.layoutSubtreeIfNeeded() }
    }
    private func editors(_ view: NSView) -> [NotesTextView] {
        (view as? NotesTextView).map { [$0] } ?? view.subviews.flatMap(editors)
    }
    private func accessibilityTree(_ root: NSObject) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        func walk(_ node: NSObject) -> [NSObject] {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return [] }
            let children = node.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? node.value(forKey: "accessibilityChildren") as? [Any] ?? [] : []
            return [node] + NSAccessibilityUnignoredChildren(children).compactMap { $0 as? NSObject }.flatMap(walk)
        }
        return walk(root)
    }
    private func close(_ window: NSWindow) { window.contentViewController = nil; window.toolbar = nil; window.close() }

    @Test func textSizeChangesPreserveDocumentSelectionAndUndo() throws {
        let h = NotesEditorTests.Harness(typed: "## 日本語 👋\n- [ ] Tell **Maya**\nKeep this caret")
        let view = h.editor.textView
        let index = (h.text as NSString).range(of: "caret").location
        view.setSelectedRange(NSRange(location: index, length: 5))
        h.type("selection")
        let text = h.text
        let selection = NSRange(location: (text as NSString).range(of: "selection").location + 2, length: 3)
        view.setSelectedRange(selection)
        let beforeFont = try #require(view.textStorage?.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont)
        for _ in 0..<8 { h.model.perform(.biggerText); h.editor.update() }
        #expect(h.model.textSize.factor == 2)
        #expect(view.string == text && h.model.document.text == text)
        #expect(view.selectedRange() == selection)
        #expect(view.accessibilityValue() == text)
        #expect(view.accessibilitySelectedTextRange() == selection)
        let afterFont = try #require(view.textStorage?.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont)
        #expect(abs(afterFont.pointSize - beforeFont.pointSize * 2) < 0.1)
        #expect(h.editor.undo.canUndo)
        h.editor.undo.undo()
        #expect(h.text.contains("Keep this caret") && h.text == h.model.document.text)
        h.editor.undo.redo()
        #expect(h.text == text)
        h.model.perform(.actualSize); h.editor.update()
        #expect(h.model.textSize.factor == 1 && view.string == text)
        #expect(NotesModel().textSize.factor == 1)
    }

    @Test func standardAXTaskActionEditsSameDocumentAndUndoes() throws {
        let h = NotesEditorTests.Harness(typed: "## 日本語 👋\n- [ ] Tell **Maya**\n- [x] Book room")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = h.editor.scrollView
        defer { close(window) }
        h.editor.scrollView.frame = window.contentLayoutRect
        h.editor.textView.setFrameSize(NSSize(width: 600, height: 600))
        h.editor.textView.textLayoutManager?.ensureLayout(for: h.editor.textView.textLayoutManager!.documentRange)
        let view = h.editor.textView
        let selected = NSRange(location: (h.text as NSString).range(of: "room").location, length: 4)
        view.setSelectedRange(selected)
        let tasks = accessibilityTree(window).compactMap { $0 as? NotesTaskAccessibilityElement }
        #expect(view.accessibilityLabel() == "Notes editor")
        #expect(tasks.count == 2)
        let task = try #require(tasks.first)
        #expect(task.accessibilityRole() == .checkBox)
        #expect(task.isAccessibilityElement())
        #expect(task.accessibilityLabel() == "Tell Maya")
        #expect((task.accessibilityValue() as? NSNumber)?.boolValue == false)
        #expect(task.accessibilityFrame().width > 0)
        #expect(task.isAccessibilitySelectorAllowed(#selector(NotesTaskAccessibilityElement.accessibilityPerformPress)))
        let before = h.text
        #expect(task.accessibilityPerformPress())
        #expect(h.text == h.model.document.text && h.text.contains("- [x] Tell **Maya**"))
        #expect(view.selectedRange() == selected)
        #expect(h.reported.last?.2 == .toggleTask)
        #expect((task.accessibilityValue() as? NSNumber)?.boolValue == true)
        h.editor.undo.undo()
        #expect(h.text == before && view.accessibilityValue() == before)
        print("AX Notes editor: role=\(String(describing: view.accessibilityRole())) native UTF16=\(before.utf16.count) selection=\(view.accessibilitySelectedTextRange()); task role=\(String(describing: task.accessibilityRole())) label=\(task.accessibilityLabel() ?? "") AXPress=true document toggle=true undo=true frame=\(task.accessibilityFrame())")
        let oldID = h.model.document.id
        var other = NotesDocument()
        other.userEdit(NSRange(location: 0, length: 0), before)
        h.model.document = other
        h.editor.update()
        #expect(h.model.document.id != oldID && h.text == before)
        #expect(!task.accessibilityPerformPress(), "A stale node must refuse another document even with identical text")
        let fresh = try #require(accessibilityTree(window).compactMap { $0 as? NotesTaskAccessibilityElement }.first)
        #expect(fresh.accessibilityPerformPress())
        h.editor.undo.undo()
        h.type("prefix\n", at: 0)
        #expect(!fresh.accessibilityPerformPress(), "An old accessibility node cannot toggle another line after offsets move")
    }

    @Test func deletingNowRequiresAnExplicitConfirmationAndCancelPreservesAudio() {
        let library = NotesLibraryModel()
        let id = UUID()
        let entry = NotesLibraryEntry(id: id, title: "Kept interview", createdAt: Date(), updatedAt: Date(), deletedAt: Date(), audioBytes: 1024)
        library.deleted = [entry]
        var purged: [UUID] = []
        library.onPurge = { id in purged.append(id); library.deleted.removeAll { $0.id == id } }
        library.requestPurge(id)
        #expect(library.confirmingPurge?.id == id && purged.isEmpty)
        library.resolvePurge(confirm: false)
        #expect(library.deleted.first?.id == id && library.deleted.first?.audioBytes == 1024 && purged.isEmpty)
        library.requestPurge(id)
        library.resolvePurge(confirm: true)
        #expect(purged == [id] && library.deleted.isEmpty && library.confirmingPurge == nil)
        library.resolvePurge(confirm: true)
        #expect(purged == [id])
    }

    @Test func renderOwnedReviewMatrix() throws {
        let output = URL(fileURLWithPath: "/tmp/chirp-mac-modern-after")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scene in Snapshots.modernUXScenarios {
            for appearance in Snapshots.appearances {
                let png = try #require(Snapshots.png(scene, appearance: appearance.appearance), "Failed to render \(scene.name)")
                try png.write(to: output.appendingPathComponent("\(scene.name)-\(appearance.name).png"))
            }
        }
    }

    @Test func transcriptKeepsUsefulNoteMeasureAcrossWindowSizes() throws {
        let model = NotesModel()
        model.document = Snapshots.demoNotes()
        let library = NotesLibraryModel()
        library.selection = .note(model.document.id)
        library.showsInspector = true
        let window = Snapshots.notesWindow(model, library, size: CGSize(width: 760, height: 460))
        defer { close(window) }
        for width: CGFloat in [760, 900, 1120, 760, 1120] {
            window.setContentSize(CGSize(width: width, height: 460))
            settle(window)
            let editor = try #require(window.contentView.flatMap { editors($0).first })
            let measure = editor.frame.width - 2 * editor.textContainerInset.width
            #expect(measure >= 320, "Window \(width): text measure \(measure)")
            #expect(library.showsInspector, "Automatic presentation changes must preserve the user's preference")
            print("UX geometry window=\(width) editor=\(editor.frame.width) measure=\(measure)")
        }
    }
}
