import ChirpCore
import ChirpIOSCore
import SwiftUI
import UniformTypeIdentifiers

enum NotesPane: Hashable { case notes, transcript }

/// The Notes tab: Record/Pause/Stop, the live Markdown notes (editable) and the transcript. On iPad (regular width)
/// notes and transcript sit side by side; on iPhone a picker switches between them.
struct LiveNotesView: View {
    @ObservedObject var notes: LiveNotesController
    @ObservedObject var session: SessionCoordinator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pane = NotesPane.notes
    @State private var showRaw = false
    @State private var preview = false
    @State private var exporting = false
    @State private var confirmNew = false
    @State private var confirmUndo = false
    @State private var confirmKeep = false
    @State private var settings = false
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            if notes.recovery != nil, !notes.isActive { recoveryBanner }
            controls.padding(.horizontal).padding(.vertical, 10)
            Divider()
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    notesPane.frame(maxWidth: .infinity)
                    Divider()
                    transcriptPane.frame(maxWidth: .infinity)
                }.accessibilityElement(children: .contain).accessibilityIdentifier("chirp.notes.split")
            } else {
                Picker("Show", selection: $pane) {
                    Text("Notes").tag(NotesPane.notes)
                    Text("Transcript").tag(NotesPane.transcript)
                }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8).accessibilityIdentifier("chirp.notes.pane")
                if pane == .notes { notesPane } else { transcriptPane }
            }
        }
        .navigationTitle("Live Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .overlay(alignment: .top) {
            if notes.debugRetention {
                Text("DEBUG: Mac keeps recordings").font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(8).background(.red).allowsHitTesting(false)
            }
        }
        .fileExporter(isPresented: $exporting, document: NotesMarkdownFile(text: notes.markdown),
                      contentType: NotesMarkdownFile.markdown, defaultFilename: notes.exportName) { result in
            if case .success = result { notes.didExport() }
        }
        .sheet(isPresented: $settings) { NotesSettingsView(notes: notes) }
        .confirmationDialog("Start new notes?", isPresented: $confirmNew, titleVisibility: .visible) {
            Button("Discard and start new", role: .destructive) { notes.newNotes() }
        } message: { Text("These notes are not saved. Copy, share or save them to Files first if you want to keep them.") }
        .confirmationDialog("Undo Organize?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Restore notes before Organize", role: .destructive) { notes.undoOrganize(confirmed: true) }
        } message: { Text("You edited the notes since Organize. Restoring replaces those edits too.") }
        .confirmationDialog("Replace the current notes?", isPresented: $confirmKeep, titleVisibility: .visible) {
            Button("Replace with recovered notes", role: .destructive) { notes.keepRecovered() }
        } message: { Text("The current notes are not saved.") }
        .task { await notes.refreshHealth() }
    }

    // MARK: controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(notes.statusLine).accessibilityIdentifier("chirp.notes.status").accessibilityAddTraits(.updatesFrequently)
                } icon: {
                    Image(systemName: notes.state.isCapturing ? "record.circle.fill" : notes.isPaused ? "pause.circle" : "note.text").accessibilityHidden(true)
                }.font(.headline).foregroundStyle(notes.state.isCapturing ? Color.red : Color.primary)
                Spacer()
                if notes.state.isActive || notes.elapsed > 0 {
                    Text(ChirpNotesActivityAttributes.ContentState.clock(notes.elapsed)).font(.headline.monospacedDigit())
                        .accessibilityIdentifier("chirp.notes.elapsed")
                }
            }
            if let detail = notes.detailLine {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("chirp.notes.detail")
            }
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading) { buttons }
            }
            if session.armed, !notes.isActive {
                HStack {
                    Text("A keyboard session holds the microphone.").font(.footnote).foregroundStyle(.secondary)
                    Button("End session") { session.endSession() }.font(.footnote)
                }
            }
            if !notes.notice.isEmpty {
                Text(notes.notice).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("chirp.notes.notice")
            }
        }.controlSize(.large)
    }

    @ViewBuilder private var buttons: some View {
        switch notes.state {
        case .starting, .recording, .paused:
            Button(notes.isPaused ? "Resume" : "Pause", systemImage: notes.isPaused ? "mic.fill" : "pause.fill") {
                Task { await notes.togglePause() }
            }.buttonStyle(.bordered).keyboardShortcut("p", modifiers: [.command, .shift]).accessibilityIdentifier("chirp.notes.pause")
            Button("Stop", systemImage: "stop.fill") { Task { await notes.stop() } }
                .buttonStyle(.borderedProminent).tint(.red).keyboardShortcut("r", modifiers: [.command, .shift])
                .accessibilityIdentifier("chirp.notes.stop")
        case .stopping:
            ProgressView { Text("Finishing…") }.accessibilityIdentifier("chirp.notes.finishing")
        default:
            Button(notes.document.isEmpty && notes.document.segments.isEmpty ? "Record" : "Record more", systemImage: "record.circle") {
                Task { await notes.record() }
            }.buttonStyle(.borderedProminent).disabled(!notes.paired || notes.starting || session.armed)
                .keyboardShortcut("r", modifiers: [.command, .shift]).accessibilityIdentifier("chirp.notes.record")
        }
        Button("Organize", systemImage: "wand.and.stars") { notes.organize() }
            .buttonStyle(.bordered).disabled(!notes.canOrganize).accessibilityIdentifier("chirp.notes.organize")
        if notes.canUndoOrganize {
            Button("Undo Organize", systemImage: "arrow.uturn.backward") { if !notes.undoOrganize() { confirmUndo = true } }
                .buttonStyle(.bordered).accessibilityIdentifier("chirp.notes.undo")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Copy", systemImage: "doc.on.doc") { notes.copy() }.accessibilityIdentifier("chirp.notes.copy")
                ShareLink(item: notes.markdown, subject: Text("Notes")) { Label("Share…", systemImage: "square.and.arrow.up") }
                Button("Save to Files…", systemImage: "folder") { exporting = true }.accessibilityIdentifier("chirp.notes.save")
                Divider()
                Toggle("Preview Markdown", systemImage: "eye", isOn: $preview)
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(notes.document.isEmpty && notes.document.segments.isEmpty).accessibilityIdentifier("chirp.notes.export")
            Button("New notes", systemImage: "square.and.pencil") {
                if notes.document.isDirty, !(notes.document.isEmpty && notes.document.segments.isEmpty) { confirmNew = true } else { notes.newNotes() }
            }.disabled(notes.isActive).accessibilityIdentifier("chirp.notes.new")
            Button("Notes settings", systemImage: "gearshape") { settings = true }.accessibilityIdentifier("chirp.notes.settings")
        }
    }

    // MARK: panes

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if preview {
                ScrollView { NotesMarkdownPreview(text: notes.document.text).padding() }.accessibilityIdentifier("chirp.notes.preview")
            } else {
                TextEditor(text: Binding(get: { notes.document.text }, set: { notes.edit($0) }))
                    .font(.body).focused($editing).scrollContentBackground(.hidden).padding(.horizontal, 12)
                    .accessibilityIdentifier("chirp.notes.editor")
                    .overlay(alignment: .topLeading) {
                        if notes.document.text.isEmpty {
                            Text(notes.structuring.isOff ? "Notes stay a transcript while structuring is off. Type here to add your own."
                                                         : "Structured notes appear here as you speak. Type anywhere to add your own.")
                                .foregroundStyle(.tertiary).padding(.horizontal, 17).padding(.vertical, 8).allowsHitTesting(false)
                        }
                    }
                    .onChange(of: editing) { _, value in notes.setEditing(value) }
            }
            if !notes.document.livePartial.isEmpty {
                Divider()
                Text(notes.document.livePartial).italic().foregroundStyle(.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                    .accessibilityIdentifier("chirp.notes.partial")
            }
        }
    }

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Show raw", isOn: $showRaw).padding(.horizontal).padding(.vertical, 8)
                .accessibilityIdentifier("chirp.notes.raw")
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if notes.document.segments.isEmpty {
                        Text("The transcript appears here, segment by segment.").foregroundStyle(.tertiary)
                    }
                    ForEach(notes.document.transcriptParagraphs) { paragraph in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ChirpNotesActivityAttributes.ContentState.clock(paragraph.offset)).font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let failure = paragraph.failure {
                                Label("Not transcribed (\(failure))", systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                            } else {
                                Text(paragraph.text(raw: showRaw)).textSelection(.enabled)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }.accessibilityIdentifier("chirp.notes.transcript")
        }
    }

    private var recoveryBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Unsaved notes from an earlier session", systemImage: "arrow.counterclockwise.circle").font(.headline)
            if let record = notes.recovery {
                Text("Started \(record.document.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(ChirpNotesActivityAttributes.ContentState.clock(record.elapsed)) recorded")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack {
                Button("Keep") {
                    if notes.document.isDirty, !notes.document.isEmpty { confirmKeep = true } else { notes.keepRecovered() }
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("chirp.notes.recovery.keep")
                Button("Discard", role: .destructive) { notes.discardRecovered() }.buttonStyle(.bordered)
                    .accessibilityIdentifier("chirp.notes.recovery.discard")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.thinMaterial)
            .accessibilityElement(children: .contain).accessibilityIdentifier("chirp.notes.recovery")
    }
}

/// Where Live Notes lives: its own tab on iPad, whose tab strip has room; on iPhone, where a sixth tab would push History
/// and Settings into More, a button in the Dictate tab's toolbar (red while notes record).
struct LiveNotesEntry: ViewModifier {
    static var asTab: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    @ObservedObject var notes: LiveNotesController
    @ObservedObject var session: SessionCoordinator
    @State private var open = false
    func body(content: Content) -> some View {
        if Self.asTab {
            content
        } else {
            content
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(notes.isActive ? "Notes · recording" : "Live Notes", systemImage: notes.isActive ? "record.circle.fill" : "note.text") { open = true }
                            .labelStyle(.titleAndIcon).tint(notes.isActive ? .red : nil).accessibilityIdentifier("chirp.notes.open")
                    }
                }
                .navigationDestination(isPresented: $open) { LiveNotesView(notes: notes, session: session) }
        }
    }
}

/// A light Markdown rendering of the notes: headings, bullets, tasks and inline emphasis.
struct NotesMarkdownPreview: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in row(line) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func row(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") { inline(String(trimmed.dropFirst(4))).font(.headline) }
        else if trimmed.hasPrefix("## ") { inline(String(trimmed.dropFirst(3))).font(.title3.bold()).padding(.top, 6) }
        else if trimmed.hasPrefix("# ") { inline(String(trimmed.dropFirst(2))).font(.title2.bold()).padding(.top, 6) }
        else if trimmed.hasPrefix("- [ ] ") || trimmed.lowercased().hasPrefix("- [x] ") {
            Label { inline(String(trimmed.dropFirst(6))) } icon: { Image(systemName: trimmed.hasPrefix("- [ ] ") ? "square" : "checkmark.square") }
                .padding(.leading, line.hasPrefix("  ") ? 20 : 0)
        } else if trimmed.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); inline(String(trimmed.dropFirst(2))) }
                .padding(.leading, line.hasPrefix("  ") ? 20 : 0)
        } else if trimmed.isEmpty { Spacer().frame(height: 4) }
        else { inline(trimmed) }
    }
    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
    }
}

struct NotesMarkdownFile: FileDocument {
    static let markdown = UTType(filenameExtension: "md") ?? .plainText
    static var readableContentTypes: [UTType] { [markdown] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

struct NotesSettingsView: View {
    @ObservedObject var notes: LiveNotesController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Structure notes", isOn: Binding(get: { notes.preferences.structureEnabled(health: notes.health) }, set: { notes.setStructure($0) }))
                        .disabled(!notes.structureCanEnable).accessibilityIdentifier("chirp.notes.structure")
                    Toggle("Organize automatically", isOn: Binding(get: { notes.preferences.autoReorganize }, set: { notes.setAutoReorganize($0) }))
                } footer: { Text(notes.structureDisclosure + " Organize regroups the whole notes; Undo Organize puts them back.") }
                Section {
                    Toggle("Battery saver while locked", isOn: Binding(get: { notes.preferences.batterySaver }, set: { notes.setBatterySaver($0) }))
                        .accessibilityIdentifier("chirp.notes.batterySaver")
                } footer: { Text("While the screen is locked or Chirp is in the background, Chirp skips screen updates. Recording, structuring on your Mac and the lock-screen timer go on.") }
                Section {
                    Toggle("Keep an encrypted recovery copy", isOn: Binding(get: { notes.preferences.recoveryCopy }, set: { notes.setRecoveryCopy($0) }))
                        .accessibilityIdentifier("chirp.notes.recoveryCopy")
                } footer: { Text("Until you save or start new notes, Chirp keeps the notes and transcript encrypted on this iPhone or iPad, so a crash loses nothing. Never audio, never backed up. Turning this off deletes the copy.") }
            }
            .navigationTitle("Notes settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

extension LiveNotesController {
    var statusLine: String {
        switch state {
        case .idle: paired ? "Ready to record" : "Pair your Mac to record notes"
        case .starting: "Starting…"
        case .recording: "Recording"
        case .paused: pauseReason ?? "Paused · microphone off"
        case .stopping: "Finishing…"
        case .stopped: "Stopped"
        case .error(let message): "Stopped · \(message)"
        }
    }

    /// Structuring, Organize and the connection, one line (nil when there is nothing to say).
    var detailLine: String? {
        switch connection {
        case .offline(let kept): return "Mac offline · keeping \(ChirpNotesActivityAttributes.ContentState.clock(kept)) of audio to send later"
        case .catchingUp(let segments): return "Back online · sending \(segments) segment\(segments == 1 ? "" : "s") recorded offline"
        case .online: break
        }
        switch reorganize {
        case .organizing(let step, let of): return "Organizing · step \(step) of \(of)"
        case .running: return "Organizing…"
        case .organized(let failed, _) where failed > 0: return "Organized · \(failed) section\(failed == 1 ? "" : "s") kept as they were"
        case .conflict: return "The notes changed during Organize, so it kept your version"
        case .tooLong: return "The last section is too long to organize"
        default: break
        }
        switch structuring {
        case .running: return "Structuring on your Mac…"
        case .failed(let code): return "Structuring failed (\(code)); the next segment tries again"
        case .off(.correctionOff): return "Your Mac has clean-up off, so notes stay a transcript"
        case .off(.unsupported): return "Your Mac's chirp-server can't structure notes; update it"
        case .off(.disabled): return state.isActive ? "Structuring off · transcript only" : nil
        case .off(.waiting): return state.isActive ? "Waiting for your Mac…" : nil
        case .idle: return nil
        }
    }

    var canOrganize: Bool {
        guard state != .stopping, !document.isEmpty else { return false }
        switch reorganize {
        case .unavailable: return false
        default: return !reorganize.isRunning
        }
    }

    var exportName: String {
        "Notes " + document.startedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash)) + ".md"
    }
}
