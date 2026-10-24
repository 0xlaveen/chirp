import ChirpCore
import SwiftUI

/// The transcript inspector (⌥⌘T): one row per paragraph with its time and speaker, ▶ where the note kept the audio
/// (the row highlights while it plays), and a quiet divider where Continue recording picked the note up again.
struct NotesInspector: View {
    @Bindable var model: NotesModel
    let library: NotesLibraryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Transcript").font(.headline).foregroundStyle(NotesInk.primary).accessibilityAddTraits(.isHeader)
                if !model.document.segments.isEmpty {
                    Text(NotesLibraryText.duration(model.elapsed) ?? "")
                        .font(ChirpType.meta)
                        .foregroundStyle(NotesInk.secondary)
                }
                Spacer()
                Toggle("Raw", isOn: $model.showRaw)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Show each segment as the speech server first heard it")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if let banner = model.visibleSpeakerBanner { SpeakerBannerView(model: model, banner: banner) }
            TranscriptList(model: model, player: library.player)
        }
        .background(Color.chirp.background.ignoresSafeArea())
    }
}

/// What sits between two transcript rows: nothing, or the divider of a capture that continued the note.
private struct TranscriptItem: Identifiable {
    var row: TranscriptRow
    var continued: Date?
    var id: String { row.id }
}

private struct TranscriptList: View {
    @Bindable var model: NotesModel
    let player: NotesPlayer

    /// Rows with the Continue boundaries placed before the first row of each later capture.
    private var items: [TranscriptItem] {
        var boundaries = model.document.sessions.dropFirst().map { ($0.firstSegment, $0.startedAt) }
        return model.transcriptRows.map { row in
            var item = TranscriptItem(row: row)
            while let first = boundaries.first, first.0 <= row.paragraph.segments.upperBound {
                item.continued = first.1
                boundaries.removeFirst()
            }
            return item
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if model.document.segments.isEmpty && model.document.livePartial.isEmpty {
                        Text(model.state.isLive ? "Segments appear here as you talk." : "No transcript — this note was typed.")
                            .font(.callout)
                            .foregroundStyle(NotesInk.tertiary)
                            .padding(.vertical, 8)
                    }
                    ForEach(items) { item in
                        if let date = item.continued { ContinuedDivider(date: date) }
                        TranscriptRowView(model: model, player: player, row: item.row)
                    }
                    if !model.document.livePartial.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(model.document.livePartial)
                                .font(.system(size: 13))
                                .foregroundStyle(NotesInk.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 8)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
            } action: { _, bottom in model.transcriptAtBottom = bottom }
            .onChange(of: model.document) {
                if model.transcriptAtBottom, model.highlightedParagraph == nil, model.state.isLive { proxy.scrollTo("bottom", anchor: .bottom) }
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

/// "Continued · Oct 24, 3:12 PM", between the captures of one note.
private struct ContinuedDivider: View {
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(NotesInk.tertiary.opacity(0.5)).frame(height: 1)
            Text(NotesLibraryText.continued(date))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotesInk.secondary)
                .fixedSize()
            Rectangle().fill(NotesInk.tertiary.opacity(0.5)).frame(height: 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct TranscriptRowView: View {
    @Bindable var model: NotesModel
    let player: NotesPlayer
    let row: TranscriptRow
    @Environment(\.colorScheme) private var scheme

    /// This paragraph's segments that have kept audio, in order.
    private var audio: [(segment: Int, url: URL)] {
        var seen = Set<Int>()
        return row.paragraph.parts.compactMap { part in
            guard seen.insert(part.segment).inserted, let url = model.keptAudio[part.segment] else { return nil }
            return (part.segment, url)
        }
    }

    var body: some View {
        let p = row.paragraph
        let playing = player.isPlaying(note: model.document.id, paragraph: p.id)
        let audio = audio
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !audio.isEmpty {
                    Button {
                        player.toggle(note: model.document.id, paragraph: p.id, segments: audio)
                    } label: {
                        Image(systemName: playing ? "stop.fill" : "play.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(playing ? Color.chirp.onKoi : Color.chirp.koi)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(playing ? Color.chirp.koi : Color.chirp.koiContainer.opacity(0.8)))
                    }
                    .buttonStyle(.plain)
                    .help(playing ? "Stop" : "Play what was said here")
                    .accessibilityLabel(playing ? "Stop playback" : "Play from \(NotesDocument.timestamp(row.offset))")
                }
                Text(NotesStatus.clock(row.offset))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(playing ? Color.chirp.koi : NotesInk.secondary)
                    .help(NotesDocument.timestamp(row.offset))
                if let chip = row.chip, let person = p.person, p.failure == nil {
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
                    if let name = model.voices.suggestions[person] {
                        VoiceSuggestionChip(model: model, person: person, name: name)
                    }
                }
                if playing {
                    Text("Playing").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.chirp.koi)
                }
                Spacer(minLength: 0)
            }
            if let failure = p.failure {
                Text("⚠︎ audio not transcribed (\(failure))")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.chirp.moon)
            } else {
                paragraphText(p, hovered: model.hoveredParagraph == p.id)
                    .font(.system(size: 13))
                    .foregroundStyle(NotesInk.primary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if p.parts.contains(where: \.keptOriginal) && !model.showRaw { keptOriginal }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(background(playing: playing, highlighted: model.highlightedParagraph == p.id))
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

    private func background(playing: Bool, highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: ChirpRadius.row)
            .fill(playing ? Color.chirp.koi.opacity(scheme == .dark ? 0.16 : 0.12) : Color.chirp.koi.opacity(highlighted ? 0.12 : 0))
            .overlay(alignment: .leading) {
                if playing {
                    Capsule().fill(Color.chirp.koi).frame(width: 3).padding(.vertical, 6)
                }
            }
    }

    /// The paragraph's segments as one text; while hovered, each later segment shows its own `[hh:mm:ss]` in place.
    /// While a segment plays, its words are drawn in koi.
    private func paragraphText(_ p: TranscriptParagraph, hovered: Bool) -> Text {
        let playingSegment = player.isPlaying(note: model.document.id, paragraph: p.id) ? player.segment : nil
        return p.parts.enumerated().reduce(Text("")) { text, item in
            let (i, part) = item
            var body = Text((i == 0 ? "" : " ") + part.text(model.showRaw))
            if part.segment == playingSegment { body = body.fontWeight(.medium) }
            guard hovered, i > 0 else { return text + body }
            return text + Text(" [\(NotesDocument.timestamp(part.offset))]").font(.caption2.monospacedDigit()).foregroundColor(NotesInk.secondary) + body
        }
    }

    private var keptOriginal: some View {
        Text("kept original")
            .font(.caption2.weight(.medium))
            .foregroundStyle(NotesInk.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().strokeBorder(NotesInk.tertiary))
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
