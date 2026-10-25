import ChirpCore
import SwiftUI

/// Live Notes speaker fix-ups (issue #18 M2): the chip's menu (rename, merge, this turn is…, separate), the rename
/// field and the banner after a rename or merge. Session-only, like the names themselves.

/// A fix-up asked for from the transcript.
public enum SpeakerEdit: Equatable, Sendable {
    case rename(Int, to: String)
    case merge(Int, into: Int)
    case separate(Int)
    /// "This turn is ▸": nil is a new person.
    case reassign([SpeakerTurnRef], to: Int?)
    /// The banner's "Replace in notes".
    case replaceInNotes
    /// The banner's Undo (a replace in the notes, or a merge).
    case undo
    case dismiss
    /// Voice profiles (M3): "Yes, this is Maya", "Not Maya", "Remember this voice…", "Update … saved voice".
    case acceptVoice(Int)
    case declineVoice(Int)
    case rememberVoice(Int)
    case updateVoice(Int)
}

/// The banner over the transcript after a rename or a merge, for the document it was made in.
public struct SpeakerBanner: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// "Also replace 'Person 2' with 'Maya' in the notes?" (`count` places).
        case offerReplace(old: String, new: String, count: Int)
        case replaced(SpeakerNameReplacement)
        case merged(person: Int, name: String, into: String)
        /// A voice was saved, updated or could not be.
        case notice(String)
    }

    public var document: UUID
    public var kind: Kind

    public var text: String {
        switch kind {
        case .offerReplace(let old, let new, let count):
            "Also replace “\(old)” with “\(new)” in the notes? (\(count == 1 ? "1 place" : "\(count) places"))"
        case .replaced(let r):
            "Replaced “\(r.old)” with “\(r.new)” in the notes (\(r.changes.count == 1 ? "1 place" : "\(r.changes.count) places"))."
        case .merged(_, let name, let into): "Merged \(name) into \(into)."
        case .notice(let text): text
        }
    }
}

/// The row whose rename field is open.
public struct SpeakerRename: Equatable, Sendable {
    public var row: String
    public var person: Int
}

extension NotesModel {
    /// The banner, if it belongs to the document on screen.
    public var visibleSpeakerBanner: SpeakerBanner? {
        speakerBanner.flatMap { $0.document == document.id ? $0 : nil }
    }

    /// The banner's Undo still applies: a replace only while the notes are as it left them.
    public var speakerBannerUndoable: Bool {
        switch visibleSpeakerBanner?.kind {
        case .replaced(let r): document.version == r.version
        case .merged: true
        default: false
        }
    }

    /// Opens the rename field on `row` for `person`, prefilled with their name (empty for "Person N").
    public func beginRename(row: String, person: Int) {
        renameText = document.roster.person(id: document.roster.resolve(person))?.name ?? ""
        renaming = SpeakerRename(row: row, person: person)
    }

    public func commitRename() {
        guard let r = renaming else { return }
        renaming = nil
        onSpeakerEdit(.rename(r.person, to: renameText))
    }
}

extension NotesSession {
    /// Applies a fix-up to the document and sets the banner that follows it.
    public func editSpeakers(_ edit: SpeakerEdit) {
        let roster = recorder.document.roster
        var banner: SpeakerBanner.Kind?
        switch edit {
        case .rename(let id, let name):
            let old = roster.displayName(id)
            recorder.editSpeakers { $0.renameSpeaker(id, to: name); return [] }
            let new = recorder.document.roster.displayName(id), count = recorder.document.nameCount(old)
            if new != old, count > 0 { banner = .offerReplace(old: old, new: new, count: count) }
        case .merge(let id, let target):
            let name = roster.displayName(id), into = roster.displayName(target)
            recorder.editSpeakers { $0.mergeSpeaker(id, into: target); return [] }
            banner = .merged(person: roster.resolve(id), name: name, into: into)
        case .separate(let id):
            recorder.editSpeakers { $0.separateSpeaker(id); return [] }
        case .reassign(let refs, let person):
            recorder.editSpeakers { $0.reassignTurns(refs, to: person); return [] }
        case .replaceInNotes:
            guard case .offerReplace(let old, let new, _) = model.visibleSpeakerBanner?.kind else { return }
            var done: SpeakerNameReplacement?
            recorder.editSpeakers { d in
                done = d.replaceSpeakerName(old, with: new)
                return done?.changes ?? []
            }
            banner = done.map { .replaced($0) }
        case .undo:
            switch model.visibleSpeakerBanner?.kind {
            case .replaced(let r): recorder.editSpeakers { $0.revert(r) ?? [] }
            case .merged(let person, _, _): recorder.editSpeakers { $0.separateSpeaker(person); return [] }
            default: break
            }
        case .dismiss: break
        case .acceptVoice, .declineVoice, .rememberVoice, .updateVoice:
            editVoices(edit)
            return
        }
        model.speakerBanner = banner.map { SpeakerBanner(document: recorder.document.id, kind: $0) }
    }
}

/// The chip's menu (a click on it, or a right-click on its row): what can be done about this person and this row.
struct SpeakerMenuItems: View {
    let model: NotesModel
    let row: String
    let person: Int
    let turns: [SpeakerTurnRef]

    static let help = "Rename, merge or reassign this speaker"

    var body: some View {
        let roster = model.document.roster
        let others = roster.active.filter { $0 != roster.resolve(person) }
        Button("Rename “\(roster.displayName(person))”…") { model.beginRename(row: row, person: person) }
        Menu("Merge into") {
            ForEach(others, id: \.self) { id in
                Button(roster.displayName(id)) { model.onSpeakerEdit(.merge(person, into: id)) }
            }
        }
        .disabled(others.isEmpty)
        Menu("This turn is") {
            ForEach(others, id: \.self) { id in
                Button(roster.displayName(id)) { model.onSpeakerEdit(.reassign(turns, to: id)) }
            }
            if !others.isEmpty { Divider() }
            Button("New person") { model.onSpeakerEdit(.reassign(turns, to: nil)) }
        }
        .disabled(turns.isEmpty)
        let merged = roster.merged(into: roster.resolve(person))
        if !merged.isEmpty {
            Menu("Separate") {
                ForEach(merged, id: \.self) { id in
                    Button(roster.person(id: id)?.name ?? "Person \(id)") { model.onSpeakerEdit(.separate(id)) }
                }
            }
        }
        VoiceMenuItems(model: model, person: roster.resolve(person))
    }
}

/// A labelled row's right-click menu is the chip's; other rows keep the text's own.
struct SpeakerRowMenu: ViewModifier {
    let model: NotesModel
    let paragraph: TranscriptParagraph

    func body(content: Content) -> some View {
        if let person = paragraph.person, paragraph.failure == nil {
            content.contextMenu {
                SpeakerMenuItems(model: model, row: paragraph.id, person: person, turns: NotesDocument.turnRefs(paragraph))
            }
        } else {
            content
        }
    }
}

/// The inline rename field: Return renames, Escape cancels, blank goes back to "Person N".
struct SpeakerRenameField: View {
    @Bindable var model: NotesModel
    let person: Int

    var body: some View {
        HStack(spacing: 8) {
            TextField(model.document.roster.displayName(person), text: $model.renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit { model.commitRename() }
                .accessibilityLabel("Name for \(model.document.roster.displayName(person))")
            Button("Rename") { model.commitRename() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(10)
        .onExitCommand { model.renaming = nil }
    }
}

/// Over the transcript: "Also replace … in the notes?" after a rename, or "Merged … · Undo".
struct SpeakerBannerView: View {
    let model: NotesModel
    let banner: SpeakerBanner

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(banner.text).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if case .offerReplace = banner.kind {
                Button("Replace") { model.onSpeakerEdit(.replaceInNotes) }.controlSize(.small)
            } else if model.speakerBannerUndoable {
                Button("Undo") { model.onSpeakerEdit(.undo) }.controlSize(.small)
            }
            Button { model.onSpeakerEdit(.dismiss) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.chirp.koi.opacity(0.07))
        .overlay(alignment: .bottom) { Divider() }
    }
}
