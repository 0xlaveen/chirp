import ChirpCore
import SwiftUI

/// The Name speakers sheet (issue #247 item 3a): everyone in the note in one place, each with a name field that
/// completes from saved voices and the names used in recent notes, a ▶ of their first turn where the note kept audio,
/// and "Same as ▸" for two voices that are one person. Done applies all of it as one edit. After Stop, a quiet
/// "Who was speaking?" line opens it. The names are the note's own and are saved with it.

/// What the sheet holds while it is open; `namings(in:)` is what Done asks for.
struct NameSpeakersDraft: Equatable {
    struct Row: Identifiable, Equatable {
        var id: Int
        var name: String
        var mergeInto: Int?
        /// "Remember voice": ticked by default, asked about only where voices can be saved.
        var remember = true
    }

    var rows: [Row]
    /// "Also replace names in the notes".
    var replace = true

    init(_ document: NotesDocument) {
        rows = document.namableSpeakers.map { Row(id: $0, name: document.roster.person(id: $0)?.name ?? "") }
    }

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The rows that changed: a new name (blank puts "Person N" back) or a merge.
    func namings(in document: NotesDocument) -> [SpeakerNaming] {
        rows.compactMap { row in
            if let target = row.mergeInto { return SpeakerNaming(person: row.id, mergeInto: target) }
            let current = Self.trimmed(document.roster.person(id: row.id)?.name ?? "")
            let name = Self.trimmed(row.name)
            return name == current ? nil : SpeakerNaming(person: row.id, name: name)
        }
    }

    /// How many places in the notes the renames would change.
    func replaceCount(in document: NotesDocument) -> Int {
        namings(in: document).filter { $0.mergeInto == nil }.reduce(0) { sum, n in
            let old = document.roster.displayName(n.person)
            var roster = document.roster
            roster.rename(n.person, to: n.name)
            return roster.displayName(n.person) == old ? sum : sum + document.nameCount(old)
        }
    }

    /// The people to remember: named now, ticked, with enough speech, and not remembered already.
    func remembered(in document: NotesDocument, voices: SpeakerVoiceState) -> [Int] {
        guard voices.enabled else { return [] }
        let renamed = Set(namings(in: document).filter { $0.mergeInto == nil && !($0.name ?? "").isEmpty }.map(\.person))
        return rows.filter { renamed.contains($0.id) && $0.remember && voices.linked[$0.id] == nil && voices.canRemember.contains($0.id) }.map(\.id)
    }

    /// The name a row's chip shows: what is typed, else "Person N".
    func shown(_ row: Row, in roster: SpeakerRoster) -> String {
        let typed = Self.trimmed(row.name)
        guard typed.isEmpty else { return typed }
        var plain = roster
        plain.rename(row.id, to: nil)
        return plain.displayName(row.id)
    }
}

/// The open sheet: what is typed, and the row whose suggestions show (the first nameless one, then the one last
/// typed in). Kept on the note's model so a redraw of the window never loses it.
@MainActor @Observable
final class NameSpeakersState {
    var draft: NameSpeakersDraft
    var suggesting: Int?

    init(_ document: NotesDocument, draft: NameSpeakersDraft? = nil, suggesting: Int? = nil) {
        let draft = draft ?? NameSpeakersDraft(document)
        self.draft = draft
        self.suggesting = suggesting ?? draft.rows.first { NameSpeakersDraft.trimmed($0.name).isEmpty }?.id
    }
}

extension NotesModel {
    /// Opens the Name speakers sheet over this note's people.
    public func beginNamingSpeakers() { nameSpeakers = NameSpeakersState(document) }

    public func endNamingSpeakers() { nameSpeakers = nil }

    public var namingSpeakers: Bool { nameSpeakers != nil }

    /// After Stop (or on a note opened from the library): somebody is still "Person N" and the line was not dismissed.
    public var showsNameSpeakersLine: Bool {
        !state.isActive && !nameLineDismissed.contains(document.id) && !document.unnamedSpeakers.isEmpty
    }

    /// A person's first labelled turn: its row, the first words and the kept audio, for the ▶ in the sheet.
    func speakerSample(_ person: Int) -> (paragraph: String, text: String, audio: [(segment: Int, url: URL)])? {
        let roster = document.roster
        guard let row = transcriptRows.first(where: { $0.paragraph.failure == nil && $0.paragraph.person.map(roster.resolve) == person }),
              let first = row.paragraph.parts.first else { return nil }
        var seen = Set<Int>()
        let audio = row.paragraph.parts.compactMap { part -> (segment: Int, url: URL)? in
            guard seen.insert(part.segment).inserted, let url = keptAudio[part.segment] else { return nil }
            return (part.segment, url)
        }
        return (row.paragraph.id, Self.sampleText(first.text(false)), audio)
    }

    /// The first words of a turn, cut on a word boundary.
    static func sampleText(_ text: String, limit: Int = 72) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard words.count > limit else { return words }
        var cut = String(words.prefix(limit))
        // Drop the word the limit fell inside, unless the cut landed exactly after one.
        if words[words.index(words.startIndex, offsetBy: limit)] != " ", let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-—")) + "…"
    }
}

struct NameSpeakersSheet: View {
    @Bindable var model: NotesModel
    @Bindable var state: NameSpeakersState
    let library: NotesLibraryModel

    static let scrolls = 5

    private var draft: NameSpeakersDraft { state.draft }

    var body: some View {
        let document = model.document
        let places = draft.replaceCount(in: document)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.2").foregroundStyle(Color.chirp.koi).accessibilityHidden(true)
                Text("Name speakers").font(ChirpType.noteTitle(20)).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("Saved with this note").font(ChirpType.meta).foregroundStyle(NotesInk.secondary)
            }
            if draft.rows.isEmpty {
                Text("Nobody has been heard yet.").font(.callout).foregroundStyle(NotesInk.secondary)
            } else if draft.rows.count > Self.scrolls {
                ScrollView { list }.frame(height: 360)
            } else {
                list
            }
            Toggle(places > 0 ? "Also replace names in the notes (\(places == 1 ? "1 place" : "\(places) places"))"
                              : "Also replace names in the notes", isOn: $state.draft.replace)
                .toggleStyle(.checkbox)
                .disabled(places == 0)
            HStack {
                Spacer()
                Button("Cancel") { model.endNamingSpeakers() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { done() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .background(Color.chirp.background)
        .tint(Color.chirp.koi)
        .onDisappear { if library.player.playing?.note == model.document.id { library.player.stop() } }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(draft.rows.indices), id: \.self) { i in
                if i > 0 { Divider().padding(.leading, 4) }
                row(i)
            }
        }
        .background(RoundedRectangle(cornerRadius: ChirpRadius.row).fill(Color.chirp.surface))
        .overlay(RoundedRectangle(cornerRadius: ChirpRadius.row).strokeBorder(NotesInk.tertiary.opacity(0.4)))
    }

    private func row(_ i: Int) -> some View {
        let document = model.document
        let roster = document.roster
        let row = draft.rows[i]
        let merged = row.mergeInto != nil
        let others = draft.rows.filter { $0.id != row.id && $0.mergeInto == nil }
        let voices = model.voices
        let sample = model.speakerSample(row.id)
        let typed = NameSpeakersDraft.trimmed(row.name)
        let offered = state.suggesting == row.id && !merged
            ? SpeakerNameSuggestions.names(saved: voices.saved, recent: library.recentSpeakerNames(excluding: document.id),
                                           taking: draft.rows.filter { $0.id != row.id }.map(\.name), matching: row.name)
            : []
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SpeakerChip(name: draft.shown(row, in: roster), color: roster.colorIndex(row.id))
                    .frame(minWidth: 84, alignment: .leading)
                TextField(draft.shown(NameSpeakersDraft.Row(id: row.id, name: ""), in: roster), text: $state.draft.rows[i].name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(merged)
                    .onChange(of: row.name) { state.suggesting = row.id }
                    .accessibilityLabel("Name for \(draft.shown(NameSpeakersDraft.Row(id: row.id, name: ""), in: roster))")
                Menu {
                    ForEach(others) { other in
                        Button(draft.shown(other, in: roster)) { state.draft.rows[i].mergeInto = other.id }
                    }
                    if merged {
                        Divider()
                        Button("Not the same person") { state.draft.rows[i].mergeInto = nil }
                    }
                } label: {
                    Text(row.mergeInto.map { target in "Same as " + (draft.rows.first { $0.id == target }.map { draft.shown($0, in: roster) } ?? "") } ?? "Same as")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(others.isEmpty && !merged)
                .help("Two voices that are one person")
                if voices.enabled, voices.linked[row.id] == nil, !merged {
                    Toggle("Remember voice", isOn: $state.draft.rows[i].remember)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .disabled(typed.isEmpty || !voices.canRemember.contains(row.id))
                        .help(voices.canRemember.contains(row.id) ? "Chirp recognises this voice in later notes"
                              : VoiceText.needs(voices.seconds[row.id] ?? 0))
                }
            }
            if !offered.isEmpty {
                HStack(spacing: 6) {
                    ForEach(offered, id: \.self) { name in
                        Button(name) {
                            state.draft.rows[i].name = name
                        }
                        .buttonStyle(NameSuggestionStyle())
                        .accessibilityLabel("Use the name \(name)")
                    }
                }
                .padding(.leading, 94)
            }
            if let sample { sampleLine(sample, note: document.id) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    private func sampleLine(_ sample: (paragraph: String, text: String, audio: [(segment: Int, url: URL)]), note: UUID) -> some View {
        let playing = library.player.isPlaying(note: note, paragraph: sample.paragraph)
        return HStack(spacing: 8) {
            if !sample.audio.isEmpty {
                Button {
                    library.player.toggle(note: note, paragraph: sample.paragraph, segments: sample.audio)
                } label: {
                    Image(systemName: playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(playing ? Color.chirp.onKoi : Color.chirp.koi)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(playing ? Color.chirp.koi : Color.chirp.koiContainer.opacity(0.8)))
                }
                .buttonStyle(.plain)
                .help(playing ? "Stop" : "Hear their first words")
                .accessibilityLabel(playing ? "Stop playback" : "Play their first words")
            }
            Text("“\(sample.text)”")
                .font(.system(size: 12))
                .foregroundStyle(NotesInk.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 94)
    }

    private func done() {
        let document = model.document
        let namings = draft.namings(in: document)
        let remember = draft.remembered(in: document, voices: model.voices)
        if !namings.isEmpty { model.onSpeakerEdit(.nameSpeakers(namings, replaceInNotes: draft.replace)) }
        for person in remember { model.onSpeakerEdit(.rememberVoice(person)) }
        model.nameLineDismissed.insert(document.id)
        model.endNamingSpeakers()
    }
}

/// A name from saved voices or recent notes, offered under the field.
private struct NameSuggestionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.chirp.onKoiContainer)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.chirp.koiContainer.opacity(configuration.isPressed ? 1 : 0.7)))
    }
}

/// "Who was speaking? Name speakers": the quiet line over a stopped note that has people nobody named yet.
struct SpeakerNameLine: View {
    let model: NotesModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Who was speaking?").font(.callout).foregroundStyle(NotesInk.primary)
            Button("Name speakers") { model.beginNamingSpeakers() }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.chirp.koi)
            Spacer(minLength: 4)
            Button { model.nameLineDismissed.insert(model.document.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.chirp.koi.opacity(0.07))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}
