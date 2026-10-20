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
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            NotesFooter(model: model)
        }
        .frame(minWidth: NotesViewMetrics.minimumSize.width, minHeight: NotesViewMetrics.minimumSize.height)
        .background(Color(nsColor: .textBackgroundColor))
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

    var body: some View {
        HStack(spacing: 12) {
            RecordButton(model: model)
            status
            Spacer(minLength: 8)
            if model.tab == .notes { EditPreviewPicker(model: model) }
            Picker("Layout", selection: Binding(get: { model.tab }, set: { model.tab = $0; model.onTabChange($0) })) {
                ForEach(NotesTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 2) {
                if !model.reorganizeHidden { reorganizeButton }
                iconButton("doc.on.doc", label: "Copy Markdown", enabled: model.canExport, action: model.onCopy)
                iconButton("square.and.arrow.down", label: "Save…", enabled: model.canExport, action: model.onSave)
                iconButton("square.and.pencil", label: "New", enabled: model.canNew, action: model.onNew)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var status: some View {
        HStack(spacing: 6) {
            if model.isError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if model.isUpdating || model.isReorganizing || model.isBusy || model.state == .starting {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            }
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(model.isError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }

    private var reorganizeButton: some View {
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
                Text(NotesStatus.organizeLabel).font(.callout)
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

/// Record (a red dot) or Stop (a red square) with the elapsed time beside it.
private struct RecordButton: View {
    @Bindable var model: NotesModel

    var body: some View {
        Button(action: model.onRecordToggle) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.red.opacity(model.isRecording ? 0.18 : 0)).frame(width: 22, height: 22)
                    if model.isRecording {
                        RoundedRectangle(cornerRadius: 2.5).fill(Color.red).frame(width: 10, height: 10)
                    } else {
                        Circle().fill(Color.red).frame(width: 11, height: 11)
                    }
                }
                Text(model.isRecording ? "Stop" : "Record").font(.callout.weight(.medium))
                if model.isRecording || model.elapsed > 0 {
                    Text(model.elapsedText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!model.canToggle)
        .accessibilityLabel(model.isRecording ? "Stop notes" : "Start notes")
        .accessibilityValue(model.isRecording ? model.elapsedText : "")
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
            Text(NotesStatus.empty)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Or click to type your own notes.")
                .font(.callout)
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
        let notes = [model.retryNote, model.reorganizeNote].compactMap { $0 }
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(notes, id: \.self) { note in
                    let success = note == model.reorganizeNote && model.reorganizeNoteIsSuccess
                    Label(note, systemImage: success ? "checkmark.circle" : "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(success ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
            }
            .frame(maxWidth: NotesViewMetrics.readingWidth, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
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

/// "Organized · Undo", for 20 s after a reorganize (or until the next edit or append).
private struct UndoChip: View {
    let model: NotesModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars").font(.caption)
            Text(NotesStatus.organized).font(.caption.weight(.medium))
            Text("·").font(.caption).foregroundStyle(.secondary)
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
            BlockView(markdown: model.document.text, leading: true)
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
            Text(NotesMarkdown.inline(text))
                .font(level == 1 ? .system(size: 22, weight: .bold) : level == 2 ? .title3.bold() : .headline)
                .padding(.top, first && leading ? 0 : level == 3 ? 8 : 18)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
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
                    if model.transcriptAtBottom { proxy.scrollTo("bottom", anchor: .bottom) }
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
        let s = r.segment
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            stamp(r.offset)
            VStack(alignment: .leading, spacing: 3) {
                if let turn = r.turn {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let chip = r.chip { SpeakerChip(name: chip.name, color: chip.color, approximate: chip.approximate) }
                        Text(model.showRaw ? turn.raw : turn.text)
                            .font(.system(size: 13))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if (turn.keptOriginal || s.keptOriginal) && !model.showRaw { keptOriginal }
                } else if let failure = s.failure {
                    Text("⚠︎ audio not transcribed (\(failure))")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                } else {
                    Text(model.showRaw ? s.raw : s.text)
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if s.keptOriginal && !model.showRaw { keptOriginal }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.privacyLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if model.debugRetention {
                Text("DEBUG: recording kept")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
            }
            Spacer(minLength: 8)
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
            Toggle(NotesStatus.speakerLabels, isOn: Binding(get: { model.speakerLabels },
                                                             set: { model.onSpeakerLabelsToggle($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .help(NotesStatus.speakerHelp)
                .disabled(model.isRecording || model.isBusy || model.speakerModel.isDownloading)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }
}
