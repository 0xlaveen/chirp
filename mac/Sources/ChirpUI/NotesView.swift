import ChirpCore
import SwiftUI

/// Sizes the Notes window and its snapshots share.
public enum NotesViewMetrics {
    public static let defaultSize = CGSize(width: 1120, height: 720)
    public static let minimumSize = CGSize(width: 760, height: 460)
    /// Notes read best at a comfortable measure, however wide the window.
    static let readingWidth: CGFloat = 680
    /// The library sidebar's width range, and the transcript inspector's.
    static let sidebar = (min: CGFloat(260), ideal: CGFloat(280), max: CGFloat(320))
    static let inspector = (min: CGFloat(260), ideal: CGFloat(300), max: CGFloat(420))
}

/// Label colours as AppKit's semantic colours: they follow Increase Contrast like `.primary`/`.secondary`, and keep
/// their value inside vibrant sidebars, selected rows and the inspector, where a hierarchical style can turn dark.
enum NotesInk {
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
}

/// The Live Notes window: the notes library as the sidebar, the note as the detail, and its transcript as a trailing
/// inspector, under one unified toolbar (search, New Note, the Recording capsule, ✦ Smart notes, Share/Export).
/// `model` is the recorder's note; `library` is everything around it (`NotesLibraryModel`).
public struct NotesView: View {
    @Bindable var model: NotesModel
    @Bindable var library: NotesLibraryModel

    public init(model: NotesModel, library: NotesLibraryModel = NotesLibraryModel()) {
        self.model = model
        self.library = library
    }

    private var shown: NotesModel { library.displayed(model) }

    public var body: some View {
        NavigationSplitView {
            NotesSidebar(model: model, library: library)
                .navigationSplitViewColumnWidth(min: NotesViewMetrics.sidebar.min, ideal: NotesViewMetrics.sidebar.ideal,
                                                max: NotesViewMetrics.sidebar.max)
        } detail: {
            detail
                .inspector(isPresented: Binding(get: { library.showsInspector }, set: { library.setInspector($0) })) {
                    NotesInspector(model: shown, library: library)
                        .inspectorColumnWidth(min: NotesViewMetrics.inspector.min, ideal: NotesViewMetrics.inspector.ideal,
                                              max: NotesViewMetrics.inspector.max)
                }
        }
        .searchable(text: $library.query, placement: .sidebar, prompt: "Search notes")
        .toolbar { NotesToolbar(model: model, library: library) }
        .navigationTitle(library.selection == .recentlyDeleted ? NotesLibraryText.recentlyDeleted : shown.displayTitle)
        .navigationSubtitle(subtitle)
        .frame(minWidth: NotesViewMetrics.minimumSize.width, minHeight: NotesViewMetrics.minimumSize.height)
        .overlay(alignment: .bottom) { if let toast = library.toast { NotesToastView(library: library, toast: toast) } }
        .sheet(isPresented: Binding(get: { shown.reviewing != nil }, set: { if !$0 { shown.closeReview() } })) {
            OrganizeReviewSheet(model: shown)
        }
        .alert(NotesLibraryText.switchPrompt(model.displayTitle),
               isPresented: Binding(get: { library.confirmingSwitch != nil }, set: { if !$0 { library.confirmingSwitch = nil } })) {
            Button(NotesLibraryText.stopAndContinue) {
                if let id = library.confirmingSwitch { library.onStopAndContinue(id) }
                library.confirmingSwitch = nil
            }
            Button("Cancel", role: .cancel) { library.confirmingSwitch = nil }
        } message: {
            Text("Only one note records at a time. The recording note keeps everything it has so far.")
        }
        .alert("Empty Recently Deleted?", isPresented: $library.confirmingEmpty) {
            Button("Empty", role: .destructive) { library.onEmptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(NotesLibraryText.results(library.deleted.count)) will be deleted for good, with their audio. This can’t be undone.")
        }
        // The app accent (koi): system controls in Notes follow it, bundled or not.
        .tint(Color.chirp.koi)
    }

    /// The toolbar's second line: what the recorder is doing, or when the note was last edited.
    private var subtitle: String {
        if library.selection == .recentlyDeleted { return NotesLibraryText.trashHelp }
        if shown === model, !model.headerStatusText.isEmpty, model.state != .stopped { return model.headerStatusText }
        guard !shown.isBlank else { return "" }
        let edited = library.entry(shown.document.id)?.updatedAt ?? shown.document.updatedAt
        return "Edited " + NotesLibraryText.relative(edited, now: library.now(), calendar: library.calendar).lowercasedIfTime
    }

    @ViewBuilder private var detail: some View {
        if library.selection == .recentlyDeleted {
            RecentlyDeletedView(library: library)
        } else if library.isEmpty, shown === model, model.showsEmptyState {
            NotesEmptyState(model: model, library: library)
        } else {
            NotesDetail(model: shown, active: model, library: library)
        }
    }
}

private extension String {
    /// "Edited 3:12 PM" reads as is; "Edited Yesterday" becomes "Edited yesterday".
    var lowercasedIfTime: String { self == "Yesterday" ? "yesterday" : self }
}

// MARK: detail

/// The note: banners for what needs attention, the title and editor (one scrolling page), the status lines, the
/// Hearing strip while recording, and the quiet meta bar (where structuring sends text, kept exports).
struct NotesDetail: View {
    @Bindable var model: NotesModel
    let active: NotesModel
    @Bindable var library: NotesLibraryModel

    private var isRecorder: Bool { model === active }

    var body: some View {
        VStack(spacing: 0) {
            if isRecorder {
                if let message = model.errorText {
                    ErrorBanner(text: message, action: NotesStatus.errorOpensServerSettings(message) ? ("Server Settings…", model.onServerSettings) : nil)
                }
                if let offer = model.recovery { RecoveryBanner(model: model, offer: offer) }
                if model.showsLongRunNotice { LongRunNotice(model: model) }
                if let explanation = model.explanation { ExplanationBanner(model: model, text: explanation) }
            }
            ZStack(alignment: .topTrailing) {
                NotesEditor(model: model, library: library)
                    .id(ObjectIdentifier(model))
                VStack(alignment: .trailing, spacing: 6) {
                    if model.showEditedChip { EditedChip(model: model) }
                    if model.showUndoChip { UndoChip(model: model) }
                    if model.isUpdating { UpdatingBadge() }
                }
                .padding(.top, 12)
                .padding(.trailing, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            NotesStatusLines(model: model)
            if isRecorder, model.state.isLive, !model.hearingText.isEmpty { HearingStrip(parts: model.hearingParts, text: model.hearingText) }
            NotesMetaBar(model: model)
        }
        // Under the toolbar too, so the title bar sits on the page.
        .background(Color.chirp.surface.ignoresSafeArea())
    }
}

/// The title page above the notes: a large serif title field and one quiet line of facts about the note.
struct NotesTitleHeader: View {
    @Bindable var model: NotesModel
    let library: NotesLibraryModel

    private var created: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = library.calendar.timeZone
        f.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(NotesLibraryText.untitled, text: Binding(
                get: { model.titleDraft ?? (model.isBlank && model.document.userTitle == nil ? "" : model.document.title) },
                set: { model.titleDraft = $0; model.onTitleEdit($0) }))
                .textFieldStyle(.plain)
                .font(ChirpType.noteTitle(26))
                .foregroundStyle(NotesInk.primary)
                .onSubmit { model.focusRequest += 1 }
                .accessibilityLabel("Title")
            meta
        }
        .padding(.top, 30)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meta: some View {
        let d = model.document
        let entry = library.entry(d.id)
        var facts: [String] = [created.string(from: d.createdAt)]
        if let length = NotesLibraryText.duration(model.elapsed) { facts.append(length) }
        let open = d.openTodoCount()
        if open > 0 { facts.append("☐ " + NotesLibraryText.open(open)) }
        if let bytes = entry?.audioBytes, bytes > 0 { facts.append("Audio " + NotesLibraryText.size(bytes)) }
        return HStack(spacing: 8) {
            if model.state.isLive {
                Circle().fill(Color.chirp.record).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(model.isPaused ? NotesStatus.paused : NotesLibraryText.recording)
                    .font(ChirpType.meta.weight(.semibold))
                    .foregroundStyle(Color.chirp.record)
            }
            if entry?.recovered == true { RecoveredBadge() }
            Text(facts.joined(separator: "  ·  "))
                .font(ChirpType.meta)
                .foregroundStyle(NotesInk.secondary)
                .lineLimit(1)
        }
    }
}

/// "Recovered": a capture that never received Stop, found at launch. No modal, just this mark.
struct RecoveredBadge: View {
    var body: some View {
        Text(NotesLibraryText.recovered)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.chirp.moon)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.chirp.moonFill.opacity(0.22)))
            .fixedSize()
            .help("Chirp found this note after it quit unexpectedly. Everything it had is here.")
    }
}

// MARK: toolbar

/// The unified toolbar's trailing items: the record control (or the Recording capsule), ✦ Smart notes, Share/Export and
/// the transcript inspector. New Note sits over the sidebar.
struct NotesToolbar: ToolbarContent {
    let model: NotesModel
    let library: NotesLibraryModel

    private var shown: NotesModel { library.displayed(model) }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            let note = library.selection != .recentlyDeleted
            if note || model.state.isActive { RecordControl(model: model, library: library) }
            if model.state.isLive { PauseButton(model: model) }
            if note, shown.voiceEditAvailable { VoiceEditButton(model: shown) }
            if note {
                SmartNotesMenu(model: shown, recorder: model)
                ShareMenu(model: shown)
            }
            Button {
                library.setInspector(!library.showsInspector)
            } label: {
                Label("Transcript", systemImage: "sidebar.right")
            }
            .help(library.showsInspector ? "Hide the transcript (⌥⌘T)" : "Show the transcript (⌥⌘T)")
        }
    }
}

/// Not recording: Record (a new note) or Continue (a finished one). Recording: the capsule `◉ <title> 03:12`, which
/// jumps back to the recording note from anywhere in the library, with Stop beside it.
struct RecordControl: View {
    let model: NotesModel
    let library: NotesLibraryModel

    var body: some View {
        if model.state.isActive {
            HStack(spacing: 6) {
                Button {
                    library.select(.note(model.document.id))
                } label: {
                    HStack(spacing: 7) {
                        if model.isPaused {
                            Image(systemName: "pause.circle.fill").foregroundStyle(Color.chirp.record)
                        } else {
                            Ripple(level: Double(model.level), reduceMotion: model.reduceMotion, color: .chirp.record,
                                   staticColor: .chirp.record, side: 18)
                                .overlay(Circle().fill(Color.chirp.record).frame(width: 7, height: 7))
                        }
                        Text(model.displayTitle)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: 170, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(model.elapsedText)
                            .font(ChirpType.timer(13))
                            .foregroundStyle(NotesInk.secondary)
                    }
                    .padding(.horizontal, 4)
                    .onGeometryChange(for: CGSize.self, of: \.size) { model.probe.recordLabel = $0 }
                }
                .help("Go to the recording note")
                .accessibilityLabel("Recording \(model.displayTitle), \(model.elapsedText). Go to the recording note")
                Button(action: model.onRecordToggle) {
                    Image(systemName: "stop.fill").foregroundStyle(Color.chirp.record)
                }
                .disabled(!model.canToggle)
                .help(model.isPaused ? "Stop and finish the notes" : "Stop recording (⌘⇧R)")
                .accessibilityLabel("Stop notes")
            }
        } else {
            let shown = library.displayed(model)
            let continues = !shown.isBlank
            Button {
                if shown === model { model.onRecordToggle() } else { library.onContinue(shown.document.id) }
            } label: {
                Label {
                    Text(continues ? "Continue" : "Record")
                        .onGeometryChange(for: CGSize.self, of: \.size) { model.probe.recordLabel = $0 }
                } icon: {
                    Image(systemName: "record.circle").foregroundStyle(Color.chirp.record)
                }
                .labelStyle(.titleAndIcon)
            }
            .disabled(!model.canToggle)
            .help(continues ? "Continue recording into this note (⌘⇧R)" : "Start recording (⌘⇧R)")
            .accessibilityLabel(continues ? NotesLibraryText.continueRecording : "Start notes")
        }
    }
}

/// Pause (closes the microphone, keeps the notes open) or Resume.
private struct PauseButton: View {
    @Bindable var model: NotesModel

    var body: some View {
        Button(action: model.onPauseToggle) {
            Label(model.isPaused ? NotesStatus.resume : NotesStatus.pause, systemImage: model.isPaused ? "play.fill" : "pause.fill")
        }
        .disabled(!(model.isPaused || model.state == .recording))
        .help(model.isPaused ? "Resume recording into the same notes (⌘⇧P)" : "Pause: the microphone closes, the notes stay open (⌘⇧P)")
        .accessibilityLabel(model.isPaused ? "Resume notes" : "Pause notes")
    }
}

/// ✦ Smart notes: the switches that used to sit in the footer, and Organize.
struct SmartNotesMenu: View {
    @Bindable var model: NotesModel
    /// The recorder's model: the switches are the session's, whichever note is on screen.
    let recorder: NotesModel

    var body: some View {
        Menu {
            if !model.reorganizeHidden {
                Button(NotesStatus.organizeLabel + " Now", action: model.onReorganize).disabled(!model.canReorganize)
                Button("Restore Notes Before Organize…") { model.review() }.disabled(!model.canRestore)
                Divider()
            }
            // On while downloading too, so switching it off cancels the download.
            Toggle(NotesStatus.speakerLabels, isOn: Binding(get: { recorder.speakerLabels || recorder.speakerModel.isDownloading },
                                                             set: { recorder.onSpeakerLabelsToggle($0) }))
                .disabled(recorder.state.isActive)
            Toggle("Structure notes", isOn: Binding(get: { recorder.structureEnabled },
                                                    set: { recorder.structureEnabled = $0; recorder.onStructureToggle($0) }))
                .disabled(!recorder.structuringAvailable && recorder.structuring != .off(.disabled))
            Toggle("Auto-reorganize", isOn: Binding(get: { recorder.autoReorganize && recorder.autoReorganizeAvailable },
                                                    set: { recorder.autoReorganize = $0; recorder.onAutoReorganizeToggle($0) }))
                .disabled(!recorder.autoReorganizeAvailable)
            if let status = recorder.speakerStatus {
                Divider()
                Text(status)
            }
        } label: {
            Label("Smart notes", systemImage: model.isReorganizing ? "sparkles" : "sparkles")
                .foregroundStyle(Color.chirp.moon)
        }
        .help("Smart notes: Organize, speaker labels, structuring")
    }
}

/// Share/Export: Export Markdown… (with the "keep this file updated" option), Copy Markdown and the share sheet.
struct ShareMenu: View {
    let model: NotesModel

    var body: some View {
        Menu {
            Button(model.exportTitle, action: model.onSave).disabled(!model.canExport)
            Button("Copy Markdown", action: model.onCopy).disabled(!model.canExport)
            Divider()
            ShareLink(item: model.saveText) { Text("Share…") }.disabled(!model.canExport)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .help("Share or export this note as Markdown")
    }
}

/// Edit by Voice: starts a spoken edit; while it listens (a check in the record colour), pressing it again ends it.
private struct VoiceEditButton: View {
    let model: NotesModel

    var body: some View {
        let listening = model.voiceEdit.isListening
        Button(action: model.onVoiceEdit) {
            Label("Edit by Voice", systemImage: listening ? "checkmark.circle.fill" : "mic.badge.plus")
                .foregroundStyle(listening ? AnyShapeStyle(Color.chirp.record) : AnyShapeStyle(.primary))
        }
        .disabled(!model.canVoiceEdit)
        .help(listening ? NotesStatus.voiceEditDoneHelp : NotesStatus.voiceEditHelp)
        .accessibilityLabel(listening ? NotesStatus.voiceEditDoneHelp : NotesStatus.voiceEditHelp)
    }
}

// MARK: empty state

/// No notes yet: the Chirp glyph in its rings, what Notes is for, the shortcut as keycaps, and New note / Record.
struct NotesEmptyState: View {
    let model: NotesModel
    let library: NotesLibraryModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .strokeBorder(Color.chirp.koiDecor.opacity(0.34 - Double(i) * 0.1), lineWidth: 1.5)
                        .frame(width: 92 + CGFloat(i) * 40, height: 92 + CGFloat(i) * 40)
                }
                Circle().fill(Color.chirp.koiContainer).frame(width: 84, height: 84)
                if let glyph = ChirpBrand.tinted(.chirp.koi, size: 50) {
                    Image(nsImage: glyph)
                } else {
                    Image(systemName: "note.text").font(.system(size: 34, weight: .light)).foregroundStyle(Color.chirp.koi)
                }
            }
            .frame(height: 180)
            .accessibilityHidden(true)
            Text(NotesLibraryText.emptyTitle)
                .font(ChirpType.noteTitle(24))
                .foregroundStyle(NotesInk.primary)
                .padding(.top, 18)
            Text(NotesLibraryText.emptyBody)
                .font(.system(size: 13))
                .foregroundStyle(NotesInk.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 8)
            HStack(spacing: 6) {
                ForEach(KeycapRow.keys(model.notesKey), id: \.self) { NotesKeycap(key: $0) }
                Text("starts a note from any app")
                    .font(.system(size: 12))
                    .foregroundStyle(NotesInk.secondary)
                    .padding(.leading, 4)
            }
            .padding(.top, 18)
            HStack(spacing: 10) {
                Button {
                    library.onNew()
                    model.focusRequest += 1
                } label: {
                    Label("New Note", systemImage: "square.and.pencil").padding(.horizontal, 4)
                }
                .controlSize(.large)
                Button(action: model.onRecordToggle) {
                    Label("Record", systemImage: "record.circle").padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
            Label(NotesLibraryText.emptyPrivacy, systemImage: "lock.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(NotesInk.tertiary)
                .padding(.top, 28)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.chirp.surface.ignoresSafeArea())
    }
}

/// The shortcut's modifiers and key, one keycap each ("⌃", "⌥", "N").
enum KeycapRow {
    static func keys(_ title: String) -> [String] {
        let symbols = title.prefix { "⌃⌥⇧⌘".contains($0) }.map(String.init)
        let rest = title.dropFirst(symbols.count).trimmingCharacters(in: .whitespaces)
        return symbols + (rest.isEmpty ? [] : [String(rest.split(separator: " ").first ?? Substring(rest))])
    }
}

struct NotesKeycap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundStyle(NotesInk.primary)
            .frame(minWidth: 24, minHeight: 24)
            .padding(.horizontal, key.count > 1 ? 6 : 0)
            .background(RoundedRectangle(cornerRadius: ChirpRadius.control).fill(Color.chirp.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: ChirpRadius.control).strokeBorder(NotesInk.tertiary.opacity(0.6)))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
    }
}

// MARK: toast

/// "Note deleted · Undo" for a few seconds at the bottom of the window.
struct NotesToastView: View {
    let library: NotesLibraryModel
    let toast: NotesToast

    var body: some View {
        HStack(spacing: 14) {
            Text(toast.text).font(.callout).foregroundStyle(NotesInk.primary)
            if let id = toast.undo {
                Button("Undo") {
                    library.onRestore(id)
                    library.toast = nil
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.chirp.koi)
                .keyboardShortcut("z", modifiers: .command)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.chirp.surfaceRaised))
        .overlay(Capsule().strokeBorder(NotesInk.tertiary.opacity(0.35)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.bottom, 22)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: toast.serial) {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled, library.toast?.serial == toast.serial { library.toast = nil }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: banners

/// What went wrong, under the toolbar (the subtitle only says there is a problem).
struct ErrorBanner: View {
    let text: String
    /// A way to fix it, when there is one (the server or its token: Settings › Server).
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(Color.chirp.record).accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action { Button(action.title, action: action.run).controlSize(.small) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.chirp.record.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: action == nil ? .combine : .contain)
    }
}

/// After every 2 h of recording, once: a reminder that the microphone is still open. It never stops anything itself.
private struct LongRunNotice: View {
    let model: NotesModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Color.chirp.moon).accessibilityHidden(true)
            Text(NotesStatus.longRun(hours: model.longRunHours) + " — the microphone is still open.")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(NotesStatus.stopRecording, action: model.onRecordToggle).controlSize(.small)
            Button(NotesStatus.keepGoing) { model.keepGoing() }.controlSize(.small).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.chirp.moonFill.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

/// A session the legacy journal found at launch (clients without a library): Keep restores it as a stopped document.
private struct RecoveryBanner: View {
    @Bindable var model: NotesModel
    let offer: RecoveryOffer

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.chirp.koi)
                .accessibilityHidden(true)
            Text(offer.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Keep", action: model.onRecoveryKeep)
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
                .disabled(model.isBusy || model.state.isActive)
            Button("Save…", action: model.onRecoverySave)
                .controlSize(.small)
            Button("Discard", role: .destructive, action: model.onRecoveryDiscard)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.chirp.koi.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

/// Why structuring is off, above the editor (which stays editable).
private struct ExplanationBanner: View {
    @Bindable var model: NotesModel
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "text.badge.star")
                .font(.system(size: 15))
                .foregroundStyle(Color.chirp.moon)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.offersModels {
                Button("Manage Local Models…", action: model.onManageModels)
                    .controlSize(.small)
            }
            if let fix = model.serverFix {
                Button(fix.buttonTitle, action: model.onFixServer)
                    .controlSize(.small)
                    .disabled(model.serverFixMessage?.hasSuffix("…") == true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.chirp.moonFill.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: under the notes

/// The retry note for appends, the reorganize note and the microphone warning, under the notes.
private struct NotesStatusLines: View {
    let model: NotesModel

    var body: some View {
        let notes = [model.micNote, model.retryNote, model.reorganizeNote, model.voiceEditNote].compactMap { $0 }
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(notes, id: \.self) { note in
                    let success = note == model.reorganizeNote && model.reorganizeNoteIsSuccess
                    Label(note, systemImage: success ? "checkmark.circle" : note == model.micNote ? "mic.slash" : "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(success ? AnyShapeStyle(Color.chirp.lily) : AnyShapeStyle(Color.chirp.moon))
                }
            }
            .frame(maxWidth: NotesViewMetrics.readingWidth, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .task(id: model.voiceEdit) {
                // A voice edit's note goes after a while; the other notes stay until their state changes.
                guard model.voiceEditNote != nil else { return }
                try? await Task.sleep(for: .seconds(12))
                if !Task.isCancelled { model.onVoiceEditDismiss() }
            }
        }
    }
}

/// Speech not yet in the notes: the unstructured window text, then the live partial. Never editable.
private struct HearingStrip: View {
    let parts: [HearingPart]
    let text: String

    /// The words, with each speaker's name in their colour where the speaker changes (labels on).
    private var line: Text {
        parts.enumerated().reduce(Text("")) { line, item in
            let (i, part) = item
            var run = Text(i == 0 ? "" : " ")
            if let name = part.name {
                run = run + Text(name + ": ").fontWeight(.semibold).foregroundColor(SpeakerPalette.color(part.color))
            }
            return line + run + Text(part.text)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.chirp.koi)
                .accessibilityHidden(true)
            Text("Hearing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(NotesInk.secondary)
            line
                .font(.system(size: 13))
                .foregroundStyle(NotesInk.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: NotesViewMetrics.readingWidth, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.chirp.koiContainer.opacity(0.35))
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hearing: \(text)")
    }
}

/// The few facts that must stay visible but need no space of their own: where structuring sends the text, a kept
/// export, the speaker model, the debug-retention warning, and how far the notes lag.
private struct NotesMetaBar: View {
    @Bindable var model: NotesModel

    var body: some View {
        let keep = model.keepSaving.text
        if model.structuringHost != nil || keep != nil || model.debugRetention || model.speakerStatus != nil || model.lagText != nil {
            HStack(spacing: 10) {
                if let lag = model.lagText { LagChip(model: model, text: lag) }
                if let host = model.structuringHost { StructuringChip(model: model, host: host) }
                if let keep {
                    Label(keep, systemImage: model.keepSaving.isSaving ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(model.keepSaving.isSaving ? AnyShapeStyle(NotesInk.secondary) : AnyShapeStyle(Color.chirp.moon))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let status = model.speakerStatus {
                    HStack(spacing: 4) {
                        if model.speakerModel.isDownloading { ProgressView().controlSize(.mini) }
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(model.speakerModel.isFailure ? AnyShapeStyle(Color.chirp.moon) : AnyShapeStyle(NotesInk.secondary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if model.debugRetention {
                    Text(MenuContent.debugRetention)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.chirp.record))
                        .fixedSize()
                        .help(MenuContent.debugRetentionHelp)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .overlay(alignment: .top) { Divider().opacity(0.6) }
        }
    }
}

/// "Notes 1:20 behind": the notes lag the speech; a click shows what they have not caught up with yet.
private struct LagChip: View {
    @Bindable var model: NotesModel
    let text: String

    var body: some View {
        Button { model.showsBacklog.toggle() } label: {
            Label(text, systemImage: "hourglass")
                .font(.caption.weight(.medium).monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.chirp.moonFill.opacity(0.2)))
                .foregroundStyle(Color.chirp.moon)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Speech the notes have not caught up with yet")
        .accessibilityHint("Shows the speech that is not in the notes yet")
        .popover(isPresented: $model.showsBacklog, arrowEdge: .top) {
            ScrollView {
                Text(model.hearingText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(width: 380, height: 240)
        }
    }
}

/// "Structuring → llm.example.com": where the text goes when it leaves this Mac. Never truncated: the host is the
/// part that matters.
struct StructuringChip: View {
    let model: NotesModel
    let host: String

    var body: some View {
        Label(NotesStatus.structuringChip(host), systemImage: "arrow.up.forward.circle")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.chirp.moon)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.chirp.moonFill.opacity(0.16)))
            .overlay(Capsule().strokeBorder(Color.chirp.moon.opacity(0.4)))
            .onGeometryChange(for: CGSize.self, of: \.size) { model.probe.structuringChip = $0 }
            .help("Structuring sends the notes text to \(host). Audio stays on the server you chose.")
    }
}

// MARK: chips over the notes

/// "Edited · Undo", for 20 s after a voice edit (or until the next edit or a click).
private struct EditedChip: View {
    let model: NotesModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.badge.plus").font(.caption).foregroundStyle(Color.chirp.moon)
            Text(NotesStatus.edited).font(.caption.weight(.medium))
            Text("·").font(.caption).foregroundStyle(NotesInk.secondary)
            Button {
                model.undoEdit()
                model.onVoiceEditDismiss()
            } label: {
                Text("Undo").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.chirp.koi)
            .accessibilityLabel("Undo the spoken edit")
        }
        .modifier(ChipStyle())
        .task(id: model.voiceEdit) {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { model.onVoiceEditDismiss() }
        }
    }
}

/// "Organized · Show changes · Undo", for 20 s after a reorganize (or until the next edit or append).
private struct UndoChip: View {
    let model: NotesModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.caption).foregroundStyle(Color.chirp.moon)
            Text(NotesStatus.organized).font(.caption.weight(.medium))
            Text("·").font(.caption).foregroundStyle(NotesInk.secondary)
            if model.snapshots.latest != nil {
                Button {
                    model.review()
                } label: {
                    Text("Show changes").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.chirp.koi)
                .accessibilityLabel("Show what organize changed")
                Text("·").font(.caption).foregroundStyle(NotesInk.secondary)
            }
            Button {
                model.undoReorganize()
                model.dismissUndoChip()
            } label: {
                Text("Undo").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.chirp.koi)
            .accessibilityLabel("Undo organize")
        }
        .modifier(ChipStyle())
        .task(id: model.reorganizeStatus) {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { model.dismissUndoChip() }
        }
    }
}

private struct UpdatingBadge: View {
    var body: some View {
        Label("Updating", systemImage: "sparkles")
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.chirp.moon)
            .modifier(ChipStyle())
    }
}

/// A small floating capsule over the notes (solid, so it reads over any text).
private struct ChipStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.chirp.surfaceRaised))
            .overlay(Capsule().strokeBorder(NotesInk.tertiary.opacity(0.3)))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}

/// The one-time tip about the tinted AI text (shown in a popover by the editor).
struct NotesTipView: View {
    var body: some View {
        Label(NotesStatus.tip, systemImage: "sparkles")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(width: 280, alignment: .leading)
    }
}
