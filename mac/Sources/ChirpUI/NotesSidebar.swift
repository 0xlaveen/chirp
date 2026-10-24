import ChirpCore
import SwiftUI

/// The library sidebar: the pinned Recording section, the notes by date (or the search results), and Recently Deleted
/// at the bottom. Return renames the selected row inline; ⌫ moves it to Recently Deleted (with Undo).
struct NotesSidebar: View {
    @Bindable var model: NotesModel
    @Bindable var library: NotesLibraryModel
    @Environment(\.undoManager) private var undoManager

    /// The recorder's note while the library has not kept it yet (a new note, or one not written yet), so the list
    /// shows what the detail shows.
    private var pending: NotesLibraryEntry? {
        let d = model.document
        guard library.selection == .note(d.id), library.entry(d.id) == nil, !(model.isBlank && library.isEmpty) else { return nil }
        return NotesLibraryEntry(id: d.id, title: model.displayTitle, snippet: d.snippet(), openTodos: d.openTodoCount(),
                                 createdAt: d.createdAt, updatedAt: d.updatedAt, duration: model.elapsed)
    }

    private var recordingEntry: NotesLibraryEntry? {
        guard let id = library.recordingID else { return nil }
        let d = model.document
        let kept = library.entry(id)
        return NotesLibraryEntry(id: id, title: id == d.id ? model.displayTitle : kept?.title ?? NotesLibraryText.untitled,
                                 snippet: id == d.id ? d.snippet() : kept?.snippet ?? "", openTodos: kept?.openTodos ?? 0,
                                 createdAt: kept?.createdAt ?? d.createdAt, updatedAt: kept?.updatedAt ?? d.updatedAt,
                                 duration: model.elapsed, recording: true)
    }

    var body: some View {
        List(selection: Binding(get: { library.selection }, set: { library.select($0) })) {
            if let results = library.results {
                if !results.isEmpty {
                    Section {
                        ForEach(results) { result in
                            row(result.entry, highlight: result)
                        }
                    } header: {
                        SidebarHeader(title: NotesLibraryText.results(results.count))
                    }
                }
            } else {
                if let recording = recordingEntry {
                    Section {
                        RecordingRow(model: model, entry: recording)
                            .tag(NotesSidebarItem.note(recording.id))
                            .listRowBackground(SelectionBackground(selected: library.selection == .note(recording.id)))
                    } header: {
                        SidebarHeader(title: NotesLibraryText.recording)
                    }
                }
                ForEach(library.groups(pending: pending)) { group in
                    Section {
                        ForEach(group.entries) { row($0, highlight: nil) }
                    } header: {
                        SidebarHeader(title: group.title)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay { overlay }
        .onDeleteCommand { trashSelection() }
        .onKeyPress(.return) {
            guard library.renaming == nil, let id = library.selection?.noteID, library.entry(id) != nil else { return .ignored }
            library.beginRename(id)
            return .handled
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { RecentlyDeletedButton(library: library) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    library.onNew()
                } label: {
                    Label(NotesLibraryText.newNote, systemImage: "square.and.pencil")
                }
                .help("New note (⌘N)")
            }
        }
    }

    @ViewBuilder private var overlay: some View {
        if let results = library.results, results.isEmpty {
            SidebarMessage(symbol: "magnifyingglass", title: NotesLibraryText.noResults(library.query),
                           detail: "Search looks through titles, notes and transcripts.")
        } else if library.results == nil, library.isEmpty, pending == nil {
            SidebarMessage(symbol: "note.text", title: "No notes yet", detail: nil)
        }
    }

    private func row(_ entry: NotesLibraryEntry, highlight: NotesSearchResult?) -> some View {
        NoteRow(entry: entry, library: library, highlight: highlight,
                renaming: Binding(get: { library.renaming == entry.id }, set: { if !$0 { library.renaming = nil } }))
            .tag(NotesSidebarItem.note(entry.id))
            .listRowBackground(SelectionBackground(selected: library.selection == .note(entry.id)))
            .contextMenu { menu(entry) }
    }

    @ViewBuilder private func menu(_ entry: NotesLibraryEntry) -> some View {
        Button("Rename") { library.beginRename(entry.id) }
        if entry.id != library.recordingID {
            Button(NotesLibraryText.continueRecording) { library.onContinue(entry.id) }
        }
        Divider()
        Button("Delete", role: .destructive) { trash(entry.id) }
            .disabled(!library.canTrash(entry.id))
    }

    private func trashSelection() {
        guard let id = library.selection?.noteID else { return }
        trash(id)
    }

    /// Recently Deleted, the toast's Undo and ⌘Z (the window's undo manager, while the list has the keyboard).
    private func trash(_ id: UUID) {
        guard library.canTrash(id) else { NSSound.beep(); return }
        library.onTrash(id)
        undoManager?.registerUndo(withTarget: library) { $0.onRestore(id); $0.toast = nil }
        undoManager?.setActionName("Delete Note")
    }
}

/// A library section header: the serif, sentence case (never all caps).
private struct SidebarHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12.5, weight: .semibold, design: .serif))
            .foregroundStyle(NotesInk.secondary)
            .textCase(nil)
            .padding(.top, 4)
    }
}

/// The selected row: a koi-container tint in light, a koi wash in dark (the dark container reads muddy on a surface
/// this large), so selection reads as Chirp's and not the system's blue.
struct SelectionBackground: View {
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: ChirpRadius.row)
            .fill(selected ? (scheme == .dark ? Color.chirp.koi.opacity(0.2) : Color.chirp.koiContainer.opacity(0.85)) : .clear)
            .overlay(RoundedRectangle(cornerRadius: ChirpRadius.row)
                .strokeBorder(selected && scheme == .dark ? Color.chirp.koi.opacity(0.35) : .clear))
            .padding(.horizontal, 10)
    }
}

/// A note in the list: serif title and time, a two-line snippet, and the meta line (duration, open to-dos).
private struct NoteRow: View {
    let entry: NotesLibraryEntry
    @Bindable var library: NotesLibraryModel
    let highlight: NotesSearchResult?
    @Binding var renaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if renaming {
                    TextField("Title", text: $library.renameText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13.5, weight: .semibold, design: .serif))
                        .onSubmit { library.commitRename() }
                        .onExitCommand { library.renaming = nil }
                } else {
                    Text(entry.title)
                        .font(.system(size: 14, weight: .semibold, design: .serif))
                        .foregroundStyle(NotesInk.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(NotesLibraryText.relative(entry.updatedAt, now: library.now(), calendar: library.calendar))
                    .font(.system(size: 11))
                    .foregroundStyle(NotesInk.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            snippet
                .font(.system(size: 12))
                .foregroundStyle(NotesInk.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            MetaLine(entry: entry)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var snippet: some View {
        if let highlight, !highlight.matches.isEmpty {
            Text(Self.highlighted(highlight))
        } else if entry.snippet.isEmpty {
            Text("No additional text").foregroundStyle(NotesInk.tertiary)
        } else {
            Text(NotesLibraryText.plain(entry.snippet))
        }
    }

    /// The snippet with every match in koi on its container tint.
    static func highlighted(_ result: NotesSearchResult) -> AttributedString {
        // Newlines become spaces one for one, so the UTF-16 match ranges still line up.
        let text = result.snippet.replacingOccurrences(of: "\n", with: " ")
        var out = AttributedString(text)
        let ns = text as NSString
        for match in result.matches where NSMaxRange(match) <= ns.length {
            guard let range = Range(match, in: text), let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].foregroundColor = Color.chirp.onKoiContainer
            out[lower..<upper].backgroundColor = Color.chirp.koiContainer
            out[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return out
    }
}

/// "12 min · ☐ 3 open · Recovered".
private struct MetaLine: View {
    let entry: NotesLibraryEntry

    var body: some View {
        let length = NotesLibraryText.duration(entry.duration)
        if length != nil || entry.openTodos > 0 || entry.recovered || entry.hasAudio {
            HStack(spacing: 10) {
                if let length {
                    Label(length, systemImage: entry.hasAudio ? "waveform" : "mic")
                }
                if entry.openTodos > 0 {
                    Label(NotesLibraryText.open(entry.openTodos), systemImage: "square")
                }
                if entry.recovered { RecoveredBadge() }
            }
            .labelStyle(MetaLabelStyle())
            .font(.system(size: 11))
            .foregroundStyle(NotesInk.tertiary)
            .padding(.top, 1)
        }
    }
}

private struct MetaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// The pinned Recording row: the Ripple, the live timer and the frozen preview of what it holds so far.
private struct RecordingRow: View {
    let model: NotesModel
    let entry: NotesLibraryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                if model.isPaused {
                    Image(systemName: "pause.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.chirp.record)
                } else {
                    Ripple(level: Double(model.level), reduceMotion: model.reduceMotion, phase: model.ripplePhase,
                           color: .chirp.koiDecor, staticColor: .chirp.koi, side: 30)
                    Circle().fill(Color.chirp.record).frame(width: 9, height: 9)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title)
                        .font(.system(size: 14, weight: .semibold, design: .serif))
                        .foregroundStyle(NotesInk.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(model.elapsedText)
                        .font(ChirpType.timer(12, weight: .semibold))
                        .foregroundStyle(Color.chirp.record)
                }
                Text(entry.snippet.isEmpty ? (model.isPaused ? NotesStatus.paused : NotesStatus.listening) : NotesLibraryText.plain(entry.snippet))
                    .font(.system(size: 12))
                    .foregroundStyle(NotesInk.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording: \(entry.title), \(model.elapsedText)")
    }
}

/// Recently Deleted, pinned at the bottom of the sidebar with its count.
private struct RecentlyDeletedButton: View {
    let library: NotesLibraryModel

    var body: some View {
        let selected = library.selection == .recentlyDeleted
        Button {
            library.select(.recentlyDeleted)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash").foregroundStyle(selected ? Color.chirp.koi : NotesInk.secondary)
                Text(NotesLibraryText.recentlyDeleted).foregroundStyle(NotesInk.primary)
                Spacer()
                if !library.deleted.isEmpty {
                    Text("\(library.deleted.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(NotesInk.secondary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(SelectionBackground(selected: selected).padding(.horizontal, -10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider().padding(.horizontal, 12) }
        .accessibilityLabel("\(NotesLibraryText.recentlyDeleted), \(library.deleted.count) notes")
    }
}

/// A message in the middle of the list (no notes yet, no results).
private struct SidebarMessage: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(NotesInk.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(NotesInk.secondary).multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(NotesInk.tertiary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

// MARK: Recently Deleted

/// The detail for Recently Deleted: each note with its days left, Restore and Delete Now, and Empty.
struct RecentlyDeletedView: View {
    @Bindable var library: NotesLibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NotesLibraryText.recentlyDeleted).font(ChirpType.noteTitle(26)).foregroundStyle(NotesInk.primary)
                    Text(NotesLibraryText.trashHelp).font(ChirpType.meta).foregroundStyle(NotesInk.secondary)
                }
                Spacer()
                Button("Empty…") { library.confirmingEmpty = true }
                    .disabled(library.deleted.isEmpty)
                    .help(NotesLibraryText.emptyTrash)
            }
            .padding(.bottom, 18)
            if library.deleted.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "trash").font(.system(size: 30, weight: .light)).foregroundStyle(NotesInk.tertiary)
                    Text(NotesLibraryText.trashEmpty).font(.callout).foregroundStyle(NotesInk.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(library.deleted) { entry in DeletedRow(entry: entry, library: library) }
                    }
                }
            }
        }
        .frame(maxWidth: NotesViewMetrics.readingWidth, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.chirp.surface.ignoresSafeArea())
    }
}

private struct DeletedRow: View {
    let entry: NotesLibraryEntry
    let library: NotesLibraryModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.system(size: 14, weight: .semibold, design: .serif)).foregroundStyle(NotesInk.primary).lineLimit(1)
                Text(entry.snippet.isEmpty ? "No additional text" : NotesLibraryText.plain(entry.snippet))
                    .font(.system(size: 12)).foregroundStyle(NotesInk.secondary).lineLimit(1)
                if let deletedAt = entry.deletedAt {
                    Text(NotesLibraryText.daysLeft(deletedAt: deletedAt, now: library.now()))
                        .font(.system(size: 11)).foregroundStyle(NotesInk.tertiary)
                }
            }
            Spacer(minLength: 8)
            Button("Restore") { library.onRestore(entry.id) }
            Button("Delete Now", role: .destructive) { library.onPurge(entry.id) }
                .foregroundStyle(Color.chirp.record)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: ChirpRadius.row).fill(Color.chirp.surfaceRaised.opacity(0.7)))
    }
}
