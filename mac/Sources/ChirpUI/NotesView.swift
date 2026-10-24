import ChirpCore
import SwiftUI

/// Sizes the Notes window and its snapshots share.
public enum NotesViewMetrics {
    public static let defaultSize = CGSize(width: 900, height: 640)
    public static let minimumSize = CGSize(width: 560, height: 400)
    /// Notes read best at a comfortable measure, however wide the window.
    static let readingWidth: CGFloat = 720
}

/// The Live Notes window: a header with Record/Stop, the status, Edit/Preview, the layout switch, Reorganize and the
/// export buttons; the notes and/or transcript; and a footer with the privacy line and the "Structure notes" and
/// "Auto-reorganize" toggles.
public struct NotesView: View {
    @Bindable var model: NotesModel

    public init(model: NotesModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            NotesHeader(model: model)
            Divider()
            if let message = model.errorText { ErrorBanner(text: message) }
            if let offer = model.recovery { RecoveryBanner(model: model, offer: offer) }
            if model.showsLongRunNotice { LongRunNotice(model: model) }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            NotesFooter(model: model)
        }
        .frame(minWidth: NotesViewMetrics.minimumSize.width, minHeight: NotesViewMetrics.minimumSize.height)
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: Binding(get: { model.reviewing != nil }, set: { if !$0 { model.closeReview() } })) {
            OrganizeReviewSheet(model: model)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .notes: NotesPane(model: model)
        case .transcript: TranscriptPane(model: model)
        case .split:
            HSplitView {
                VStack(spacing: 0) {
                    PaneHeader(title: "Notes") { EditPreviewPicker(model: model).controlSize(.small) }
                    Divider()
                    NotesPane(model: model)
                }
                .frame(minWidth: 280)
                TranscriptPane(model: model).frame(minWidth: 240)
            }
        }
    }
}

// MARK: header

private struct NotesHeader: View {
    @Bindable var model: NotesModel

    private enum Tier { case full, noHint, icons, compact }

    var body: some View {
        // The widest layout that fits: the shortcut hint goes first, then the Pause and Organize labels, and at the
        // narrowest the layout switch becomes a menu and the other actions fold into one. The Record label never wraps.
        ViewThatFits(in: .horizontal) {
            row(.full)
            row(.noHint)
            row(.icons)
            row(.compact)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func row(_ tier: Tier) -> some View {
        HStack(spacing: 12) {
            RecordButton(model: model)
            if model.state.isLive { PauseButton(model: model, iconOnly: tier == .icons || tier == .compact) }
            status
            if tier == .full, let hint = model.hotkeyHint {
                Text(hint).font(.caption).foregroundStyle(.tertiary).lineLimit(1).layoutPriority(-2)
            }
            Spacer(minLength: 8)
            if tier == .compact {
                layoutPicker.pickerStyle(.menu).fixedSize()
                moreMenu
            } else {
                if model.tab == .notes { EditPreviewPicker(model: model) }
                layoutPicker.pickerStyle(.segmented).fixedSize()
                HStack(spacing: 2) {
                    if model.voiceEditAvailable { VoiceEditButton(model: model) }
                    if !model.reorganizeHidden { reorganizeButton(iconOnly: tier == .icons) }
                    iconButton("doc.on.doc", label: "Copy Markdown", enabled: model.canExport, action: model.onCopy)
                    iconButton("square.and.arrow.down", label: "Save…", enabled: model.canExport, action: model.onSave)
                    iconButton("square.and.pencil", label: "New", enabled: model.canNew, action: model.onNew)
                }
            }
        }
    }

    private var layoutPicker: some View {
        Picker("Layout", selection: Binding(get: { model.tab }, set: { model.select($0) })) {
            ForEach(NotesTab.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
    }

    /// The narrow header's other actions.
    private var moreMenu: some View {
        Menu {
            if model.tab != .transcript {
                Button(model.preview ? "Edit Notes" : "Preview Notes") { model.perform(.togglePreview) }
            }
            if model.voiceEditAvailable { Button("Edit Notes by Voice", action: model.onVoiceEdit).disabled(!model.canVoiceEdit) }
            if !model.reorganizeHidden {
                Button(NotesStatus.organizeLabel, action: model.onReorganize).disabled(!model.canReorganize)
            }
            Button("Copy Markdown", action: model.onCopy).disabled(!model.canExport)
            Button("Save…", action: model.onSave).disabled(!model.canExport)
            Button("New", action: model.onNew).disabled(!model.canNew)
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions")
    }

    private var status: some View {
        HStack(spacing: 6) {
            if model.isError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if model.voiceEdit.isListening {
                Image(systemName: "mic.fill").foregroundStyle(.red).accessibilityHidden(true)
            } else if model.isUpdating || model.isReorganizing || model.isBusy || model.isVoiceEditing || model.state == .starting {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            }
            Text(model.headerStatusText)
                .font(.callout)
                .foregroundStyle(model.isError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(model.statusText)
            if let lag = model.lagText { LagChip(model: model, text: lag) }
        }
        .layoutPriority(-1)
    }

    private func reorganizeButton(iconOnly: Bool) -> some View {
        Button(action: model.onReorganize) {
            HStack(spacing: 5) {
                Group {
                    if model.isReorganizing {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .regular))
                    }
                }
                .frame(width: 16, height: 16)
                if !iconOnly { Text(NotesStatus.organizeLabel).font(.callout) }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .disabled(!model.canReorganize)
        .help(NotesStatus.organizeHelp)
        .accessibilityLabel(NotesStatus.organizeHelp)
    }

    private func iconButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 30, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Record (a red dot) or Stop (a red square) with the elapsed time beside it, and the input level while recording.
/// The label never wraps: the pill keeps its natural width and the status gives way.
private struct RecordButton: View {
    @Bindable var model: NotesModel

    private var stops: Bool { model.isRecording || model.isPaused }

    var body: some View {
        Button(action: model.onRecordToggle) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.red.opacity(model.isRecording ? 0.18 : 0)).frame(width: 22, height: 22)
                    if stops {
                        RoundedRectangle(cornerRadius: 2.5).fill(Color.red).frame(width: 10, height: 10)
                    } else {
                        Circle().fill(Color.red).frame(width: 11, height: 11)
                    }
                }
                Text(stops ? NotesStatus.stopRecording : "Record")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self, of: \.size) { model.probe.recordLabel = $0 }
                if model.isRecording || model.elapsed > 0 {
                    Text(model.elapsedText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if model.isRecording { LevelMeter(model: model) }
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!model.canToggle)
        .help(model.isPaused ? "Stop and finish the notes" : stops ? "Stop recording (⌘⇧R)" : "Start recording (⌘⇧R)")
        .accessibilityLabel(stops ? "Stop notes" : "Start notes")
        .accessibilityValue(model.isRecording || model.isPaused ? model.elapsedText : "")
    }
}

/// One bar that rises with the microphone level (the HUD's decibel mapping), so sound arriving is visible.
private struct LevelMeter: View {
    let model: NotesModel

    var body: some View {
        let level = CGFloat(max(0, min(1, model.level)))
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.red.opacity(0.35 + 0.65 * level))
            .frame(width: 3, height: 5 + 11 * level)
            .frame(width: 3, height: 16, alignment: .bottom)
            .animation(model.reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
            .accessibilityHidden(true)
    }
}

/// Pause (closes the microphone, keeps the notes open) or Resume, beside Record/Stop.
private struct PauseButton: View {
    @Bindable var model: NotesModel
    var iconOnly = false

    var body: some View {
        Button(action: model.onPauseToggle) {
            HStack(spacing: 5) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill").font(.system(size: 11))
                if !iconOnly {
                    Text(model.isPaused ? NotesStatus.resume : NotesStatus.pause).font(.callout.weight(.medium)).lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!(model.isPaused || model.state == .recording))
        .help(model.isPaused ? "Resume recording into the same notes (⌘⇧P)" : "Pause: the microphone closes, the notes stay open (⌘⇧P)")
        .accessibilityLabel(model.isPaused ? "Resume notes" : "Pause notes")
    }
}

/// What went wrong, under the header (the header itself only says there is a problem).
struct ErrorBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(.red).accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

// MARK: notes

/// The notes: the explanation banner, the editor (or Preview), the status lines and the Hearing strip.
private struct NotesPane: View {
    @Bindable var model: NotesModel

    var body: some View {
        VStack(spacing: 0) {
            if let explanation = model.explanation {
                ExplanationBanner(model: model, text: explanation)
            }
            ZStack(alignment: .topTrailing) {
                if model.preview {
                    NotesPreview(model: model)
                } else {
                    NotesEditor(model: model)
                    if model.showsEmptyState { emptyState }
                }
                VStack(alignment: .trailing, spacing: 6) {
                    if model.showEditedChip { EditedChip(model: model) }
                    if model.showUndoChip { UndoChip(model: model) }
                    if model.isUpdating { UpdatingBadge() }
                }
                .padding(.top, 10)
                .padding(.trailing, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            NotesStatusLines(model: model)
            if !model.hearingText.isEmpty { HearingStrip(parts: model.hearingParts, text: model.hearingText) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "note.text")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(NotesStatus.empty(key: model.notesKey))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Or click to type your own notes.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Text(NotesStatus.shortcutsHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { model.focusRequest += 1 }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Start typing notes")
    }
}

/// The retry note for appends and the reorganize note, in v1's place and style.
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
                        .foregroundStyle(success ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
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
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Hearing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            line
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: NotesViewMetrics.readingWidth, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hearing: \(text)")
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
                .background(Capsule().fill(Color.orange.opacity(0.14)))
                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.45)))
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Speech the notes have not caught up with yet")
        .accessibilityHint("Shows the speech that is not in the notes yet")
        .popover(isPresented: $model.showsBacklog, arrowEdge: .bottom) {
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

/// After every 2 h of recording, once: a reminder that the microphone is still open. It never stops anything itself.
private struct LongRunNotice: View {
    let model: NotesModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange).accessibilityHidden(true)
            Text(NotesStatus.longRun(hours: model.longRunHours) + " — the microphone is still open.")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(NotesStatus.stopRecording, action: model.onRecordToggle).controlSize(.small)
            Button(NotesStatus.keepGoing) { model.keepGoing() }.controlSize(.small).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

/// Edit by Voice: starts a spoken edit; while it listens (a red check), pressing it again ends it.
private struct VoiceEditButton: View {
    let model: NotesModel

    var body: some View {
        let listening = model.voiceEdit.isListening
        Button(action: model.onVoiceEdit) {
            Image(systemName: listening ? "checkmark.circle.fill" : "mic.badge.plus")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(listening ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                .frame(width: 30, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(!model.canVoiceEdit)
        .help(listening ? NotesStatus.voiceEditDoneHelp : NotesStatus.voiceEditHelp)
        .accessibilityLabel(listening ? NotesStatus.voiceEditDoneHelp : NotesStatus.voiceEditHelp)
    }
}

/// "Edited · Undo", for 20 s after a voice edit (or until the next edit or a click).
private struct EditedChip: View {
    let model: NotesModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.badge.plus").font(.caption)
            Text(NotesStatus.edited).font(.caption.weight(.medium))
            Text("·").font(.caption).foregroundStyle(.secondary)
            Button {
                model.undoEdit()
                model.onVoiceEditDismiss()
            } label: {
                Text("Undo").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Undo the spoken edit")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .task(id: model.voiceEdit) {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { model.onVoiceEditDismiss() }
        }
    }
}

/// "Organized · Undo", for 20 s after a reorganize (or until the next edit or append).
private struct UndoChip: View {
    let model: NotesModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars").font(.caption)
            Text(NotesStatus.organized).font(.caption.weight(.medium))
            Text("·").font(.caption).foregroundStyle(.secondary)
            if model.snapshots.latest != nil {
                Button {
                    model.review()
                } label: {
                    Text("Show changes").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Show what organize changed")
                Text("·").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                model.undoReorganize()
                model.dismissUndoChip()
            } label: {
                Text("Undo").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Undo organize")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .task(id: model.reorganizeStatus) {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { model.dismissUndoChip() }
        }
    }
}

/// Preview: the same text, read-only, rendered line by line (v1's renderer).
struct NotesPreview: View {
    let model: NotesModel

    var body: some View {
        ScrollView {
            BlockView(markdown: model.document.text, leading: true, sectionOffset: { model.document.sectionOffset($0) },
                      jump: { model.jumpToTranscript(at: $0) })
                .textSelection(.enabled)
                .frame(maxWidth: NotesViewMetrics.readingWidth, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Markdown, line by line. The fallback header and the paragraphs under it are drawn secondary.
private struct BlockView: View {
    let markdown: String
    /// The first block in the pane: no space above its first heading.
    var leading = false
    /// When a heading's section was said (from speech), and the jump to it in the transcript.
    var sectionOffset: (String) -> TimeInterval? = { _ in nil }
    var jump: (TimeInterval) -> Void = { _ in }

    var body: some View {
        let blocks = NotesMarkdown.blocks(markdown)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                line(block, first: i == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func line(_ block: NotesMarkdownBlock, first: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(NotesMarkdown.inline(text))
                    .font(level == 1 ? .system(size: 22, weight: .bold) : level == 2 ? .title3.bold() : .headline)
                    .accessibilityAddTraits(.isHeader)
                if level == 2, let offset = sectionOffset(text) {
                    Button("[\(NotesDocument.timestamp(offset))]") { jump(offset) }
                        .buttonStyle(.plain)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Show in the transcript")
                        .accessibilityLabel("Show in the transcript, at \(NotesDocument.timestamp(offset))")
                }
            }
            .padding(.top, first && leading ? 0 : level == 3 ? 8 : 18)
            .padding(.bottom, 2)
        case .bullet(let indent, let text, let task, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                marker(text: text, task: task, checked: checked, nested: indent > 0)
                Text(NotesMarkdown.inline(text))
                    .font(.system(size: 14))
                    .strikethrough(checked)
                    .foregroundStyle(checked ? .secondary : .primary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 22)
        case .paragraph(let text) where text == NotesDocument.fallbackHeader:
            Text("Not structured — see transcript")
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .padding(.top, first ? 0 : 10)
        case .paragraph(let text):
            Text(NotesMarkdown.inline(text))
                .font(.system(size: 14))
                .lineSpacing(3)
                .padding(.top, first ? 0 : 4)
                .fixedSize(horizontal: false, vertical: true)
        case .placeholder:
            Text("Nothing to note yet")
                .font(.callout.italic())
                .foregroundStyle(.tertiary)
        }
    }

    /// A bullet, a task box, or a small symbol for decisions and open questions; fixed width for a hanging indent.
    @ViewBuilder private func marker(text: String, task: Bool, checked: Bool, nested: Bool) -> some View {
        Group {
            if task {
                Image(systemName: checked ? "checkmark.square" : "square").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(checked ? "Done" : "To-do")
            } else if text.hasPrefix("**Decision:**") {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(.green)
                    .accessibilityHidden(true)
            } else if text.hasPrefix("**Question:**") {
                Image(systemName: "questionmark.circle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                    .accessibilityHidden(true)
            } else {
                Text(nested ? "◦" : "•").font(.system(size: 14, weight: .bold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 14, alignment: .center)
    }
}

private struct UpdatingBadge: View {
    var body: some View {
        Label("Updating", systemImage: "sparkles")
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().fill(Color.accentColor.opacity(0.1)))
    }
}

/// A session the journal found at launch: Keep restores it as a stopped, unsaved document.
private struct RecoveryBanner: View {
    @Bindable var model: NotesModel
    let offer: RecoveryOffer

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
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
        .background(Color.accentColor.opacity(0.1))
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
                .foregroundStyle(Color.accentColor)
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
        .background(Color.accentColor.opacity(0.07))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Edit | Preview, as two small icons.
private struct EditPreviewPicker: View {
    @Bindable var model: NotesModel

    var body: some View {
        Picker("Notes view", selection: Binding(get: { model.preview }, set: { model.preview = $0; model.onPreviewToggle($0) })) {
            Image(systemName: "pencil").help("Edit").accessibilityLabel("Edit").tag(false)
            Image(systemName: "eye").help("Preview").accessibilityLabel("Preview").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(model.preview ? "Preview (read-only)" : "Edit")
    }
}

// MARK: transcript

private struct TranscriptPane: View {
    @Bindable var model: NotesModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Transcript") {
                Toggle("Show raw", isOn: $model.showRaw)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            Divider()
            if let banner = model.visibleSpeakerBanner { SpeakerBannerView(model: model, banner: banner) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.document.segments.isEmpty && model.document.livePartial.isEmpty {
                            Text("Segments appear here as you talk.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(model.transcriptRows) { row in
                            self.row(row)
                        }
                        if !model.document.livePartial.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                stamp(model.elapsed).hidden()
                                Text(model.document.livePartial)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .textSelection(.enabled)
                    .padding(16)
                }
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
                } action: { _, bottom in model.transcriptAtBottom = bottom }
                .onChange(of: model.document) {
                    if model.transcriptAtBottom, model.highlightedParagraph == nil { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.transcriptJump) {
                    guard let id = model.highlightedParagraph else { return }
                    proxy.scrollTo(id, anchor: .top)
                }
                .onAppear { if let id = model.highlightedParagraph { proxy.scrollTo(id, anchor: .top) } }
                .task(id: model.transcriptJump) {
                    guard model.highlightedParagraph != nil else { return }
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { model.highlightedParagraph = nil }
                }
            }
        }
    }

    private func stamp(_ offset: TimeInterval) -> some View {
        Text("[\(NotesDocument.timestamp(offset))]")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private func row(_ r: TranscriptRow) -> some View {
        let p = r.paragraph
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            stamp(r.offset)
            VStack(alignment: .leading, spacing: 3) {
                if let failure = p.failure {
                    Text("⚠︎ audio not transcribed (\(failure))")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let chip = r.chip, let person = p.person {
                            Menu { SpeakerMenuItems(model: model, row: p.id, person: person, turns: NotesDocument.turnRefs(p)) } label: {
                                SpeakerChip(name: chip.name, color: chip.color, approximate: chip.approximate)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help(SpeakerMenuItems.help)
                            .accessibilityLabel("Speaker: \(chip.name)")
                            .accessibilityHint(SpeakerMenuItems.help)
                        }
                        if r.chip != nil, let person = p.person, let name = model.voices.suggestions[person] {
                            VoiceSuggestionChip(model: model, person: person, name: name)
                        }
                        paragraphText(p, hovered: model.hoveredParagraph == p.id)
                            .font(.system(size: 13))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if p.parts.contains(where: \.keptOriginal) && !model.showRaw { keptOriginal }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(model.highlightedParagraph == p.id ? 0.12 : 0)))
        .modifier(SpeakerRowMenu(model: model, paragraph: p))
        .popover(isPresented: Binding(get: { model.renaming?.row == p.id }, set: { if !$0 { model.renaming = nil } }),
                 arrowEdge: .bottom) {
            if let r = model.renaming { SpeakerRenameField(model: model, person: r.person) }
        }
        .id(p.id)
        .onHover { inside in
            if inside { model.hoveredParagraph = p.id } else if model.hoveredParagraph == p.id { model.hoveredParagraph = nil }
        }
    }

    /// The paragraph's segments as one text; while hovered, each later segment shows its own `[hh:mm:ss]` in place.
    private func paragraphText(_ p: TranscriptParagraph, hovered: Bool) -> Text {
        p.parts.enumerated().reduce(Text("")) { text, item in
            let (i, part) = item
            let body = Text((i == 0 ? "" : " ") + part.text(model.showRaw))
            guard hovered, i > 0 else { return text + body }
            return text + Text(" [\(NotesDocument.timestamp(part.offset))]").font(.caption2.monospacedDigit()).foregroundColor(.secondary) + body
        }
    }

    private var keptOriginal: some View {
        Text("kept original")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
    }
}

/// A person's colour, the same in the transcript and wherever a chip shows. System colours, so both themes keep
/// their contrast.
enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]
    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

/// "Person 2" (or a name) on a capsule of the person's colour; dotted when the label is approximate (no word timings).
struct SpeakerChip: View {
    let name: String
    let color: Int
    var approximate = false

    var body: some View {
        let tint = SpeakerPalette.color(color)
        Text(name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: approximate ? [2, 2] : [])))
            .fixedSize()
            .accessibilityLabel("Speaker: \(name)" + (approximate ? ", approximate" : ""))
    }
}

/// A pane's title row, with an optional control at the right; the same height in both halves of Split.
private struct PaneHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .frame(height: 22)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: footer

private struct NotesFooter: View {
    @Bindable var model: NotesModel

    var body: some View {
        // Wide: one row. Narrow (the minimum window): the privacy line and the chip above, the switches below, so
        // nothing needs to be cut short.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                notices
                Spacer(minLength: 8)
                switches
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    notices
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    switches
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    @ViewBuilder private var notices: some View {
        Image(systemName: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        Text(model.privacyLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(model.privacyHelp)
        if let host = model.structuringHost { StructuringChip(model: model, host: host) }
        if let keep = model.keepSaving.text {
            Text(keep)
                .font(.caption)
                .foregroundStyle(model.keepSaving.isSaving ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        if model.debugRetention {
            Text("DEBUG: recording kept")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.red))
                .fixedSize()
        }
    }

    @ViewBuilder private var switches: some View {
        if let status = model.speakerStatus {
            HStack(spacing: 4) {
                if case .downloading = model.speakerModel { ProgressView().controlSize(.mini) }
                if case .loading = model.speakerModel { ProgressView().controlSize(.mini) }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(model.speakerModel.isFailure ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
        // On while downloading too, so switching it off cancels the download.
        Toggle(NotesStatus.speakerLabels, isOn: Binding(get: { model.speakerLabels || model.speakerModel.isDownloading },
                                                         set: { model.onSpeakerLabelsToggle($0) }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)
            .help(NotesStatus.speakerHelp)
            .disabled(model.state.isActive)
        Toggle("Structure notes", isOn: Binding(get: { model.structureEnabled },
                                                set: { model.structureEnabled = $0; model.onStructureToggle($0) }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)
            .disabled(!model.structuringAvailable && model.structuring != .off(.disabled))
        Toggle("Auto-reorganize", isOn: Binding(get: { model.autoReorganize && model.autoReorganizeAvailable },
                                                set: { model.autoReorganize = $0; model.onAutoReorganizeToggle($0) }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)
            .disabled(!model.autoReorganizeAvailable)
            .help(model.reorganizeHidden ? "Needs a newer Chirp server" : "Tidy the notes every few minutes while you record")
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
            .foregroundStyle(Color.orange)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.4)))
            .onGeometryChange(for: CGSize.self, of: \.size) { model.probe.structuringChip = $0 }
            .help("Structuring sends the notes text to \(host). Audio stays on the server you chose.")
    }
}

// MARK: organize review

/// What Organize changed, as a word diff, with Restore previous and Keep. The same sheet opens from the chip's Show
/// changes and from Edit ▸ Restore Notes Before Organize…, where the snapshots are listed by time.
struct OrganizeReviewSheet: View {
    @Bindable var model: NotesModel

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        let snapshot = model.reviewing.flatMap { model.snapshots.snapshot($0) }
        VStack(alignment: .leading, spacing: 12) {
            Text("What Organize changed").font(.headline)
            if model.snapshots.items.count > 1 {
                Picker("Before", selection: Binding(get: { model.reviewing ?? -1 }, set: { model.review($0) })) {
                    ForEach(model.snapshots.items.reversed()) { item in
                        Text("Before the change at \(Self.time.string(from: item.at))").tag(item.id)
                    }
                }
                .labelsHidden()
            }
            if let snapshot { diff(snapshot) }
            if model.confirmingRestore != nil {
                Label("Notes you typed since sit among the changed lines. Restoring replaces the notes with the earlier text and loses them.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Keep") { model.closeReview() }.keyboardShortcut(.cancelAction)
                if let id = model.reviewing {
                    if model.confirmingRestore == id {
                        Button("Replace notes (your later edits will be lost)", role: .destructive) { model.onRestoreSnapshot(id, true) }
                    } else {
                        Button("Restore previous") { model.onRestoreSnapshot(id, false) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.canRestore)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    @ViewBuilder private func diff(_ snapshot: NotesSnapshot) -> some View {
        ScrollView {
            Group {
                if let segments = NotesSnapshots.diff(snapshot) {
                    OrganizeDiffText(segments: segments)
                } else {
                    Text("Too long to compare word by word.").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(height: 220)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
    }
}

/// The diff as one text: removed words struck through in red, added words in green.
struct OrganizeDiffText: View {
    let segments: [WordDiff.Segment]

    var body: some View {
        segments.enumerated().reduce(Text("")) { text, item in
            let (i, seg) = item
            let word = Text((i == 0 ? "" : " ") + seg.text)
            switch seg.kind {
            case .same: return text + word
            case .removed: return text + word.strikethrough().foregroundColor(.red)
            case .added: return text + word.foregroundColor(.green).bold()
            case .changed: return text + word.foregroundColor(.orange)
            }
        }
        .accessibilityLabel(segments.map { seg in
            switch seg.kind {
            case .same: seg.text
            case .removed: "removed: \(seg.text)"
            case .added: "added: \(seg.text)"
            case .changed: "changed: \(seg.text)"
            }
        }.joined(separator: " "))
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
