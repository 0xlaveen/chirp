import ChirpCore
import SwiftUI

/// Sizes the Notes window and its snapshots share.
public enum NotesViewMetrics {
    public static let defaultSize = CGSize(width: 900, height: 640)
    public static let minimumSize = CGSize(width: 560, height: 400)
    /// Notes read best at a comfortable measure, however wide the window.
    static let readingWidth: CGFloat = 720
}

/// The Live Notes window: a header with Record/Stop, the status, the layout switch and the export buttons; the notes
/// and/or transcript; and a footer with the privacy line and the "Structure notes" toggle.
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
                    PaneHeader(title: "Notes") { EmptyView() }
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
            Picker("Layout", selection: Binding(get: { model.tab }, set: { model.tab = $0; model.onTabChange($0) })) {
                ForEach(NotesTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 2) {
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
            } else if model.isUpdating || model.isBusy || model.state == .starting {
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

private struct NotesPane: View {
    @Bindable var model: NotesModel
    @State private var atBottom = true

    var body: some View {
        if model.document.isEmpty && model.document.livePartial.isEmpty && model.explanation == nil {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let explanation = model.explanation { ExplanationCard(model: model, text: explanation) }
                        ForEach(Array(model.document.frozen.enumerated()), id: \.offset) { i, block in
                            BlockView(markdown: block.markdown, fallback: block.isFallback, leading: i == 0 && model.explanation == nil)
                        }
                        if let open = model.document.openBlock, !model.structuring.isOff {
                            BlockView(markdown: open, updating: model.isUpdating,
                                      leading: model.document.frozen.isEmpty && model.explanation == nil)
                        } else if model.isUpdating {
                            UpdatingBadge().padding(.top, 16)
                        }
                        if !model.liveTail.isEmpty {
                            Text(model.liveTail)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                                .padding(.top, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let note = model.retryNote {
                            Label(note, systemImage: "arrow.clockwise")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(.top, 10)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: NotesViewMetrics.readingWidth, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                }
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
                } action: { _, bottom in atBottom = bottom }
                .onChange(of: model.document) {
                    // Follow new text only when the reader is already at the end.
                    if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
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
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One Markdown block, line by line. A fallback block (structuring never delivered) sits on a faint card.
private struct BlockView: View {
    let markdown: String
    var fallback = false
    var updating = false
    /// The first block in the pane: no space above its first heading.
    var leading = false

    var body: some View {
        let blocks = NotesMarkdown.blocks(markdown)
        VStack(alignment: .leading, spacing: 5) {
            if updating { UpdatingBadge().padding(.top, leading ? 0 : 20).padding(.bottom, -10) }
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                line(block, first: i == 0)
            }
        }
        .padding(fallback ? 12 : 0)
        .background {
            if fallback { RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)) }
        }
        .padding(.top, fallback ? 12 : 0)
        .opacity(updating ? 0.75 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func line(_ block: NotesMarkdownBlock, first: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(NotesMarkdown.inline(text))
                .font(level == 2 ? .title3.bold() : .headline)
                .padding(.top, first && leading && !updating ? 0 : level == 2 ? 18 : 8)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
        case .bullet(let indent, let text, let task):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                marker(text: text, task: task, nested: indent > 0)
                Text(NotesMarkdown.inline(text))
                    .font(.system(size: 14))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 22)
        case .paragraph(let text):
            Text(NotesMarkdown.inline(text))
                .font(.system(size: 14))
                .foregroundStyle(fallback ? .secondary : .primary)
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
    @ViewBuilder private func marker(text: String, task: Bool, nested: Bool) -> some View {
        Group {
            if task {
                Image(systemName: "square").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .accessibilityLabel("To-do")
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
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }
}

private struct ExplanationCard: View {
    @Bindable var model: NotesModel
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.badge.star")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if model.offersModels {
                    Button("Manage Local Models…", action: model.onManageModels)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.2)))
        .padding(.bottom, 8)
    }
}

// MARK: transcript

private struct TranscriptPane: View {
    @Bindable var model: NotesModel
    @State private var atBottom = true

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
                } action: { _, bottom in atBottom = bottom }
                .onChange(of: model.document) {
                    if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }
}
