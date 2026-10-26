import ChirpCore
import ChirpIOSCore
import SwiftUI

/// Live Notes speaker labels (#201, Pond #151): the capsule that starts a person's turn, its menu (rename, same person
/// as, separate), the rename sheet and the consent before the Mac's one model download. Names are note content and are
/// never logged.

/// A person's colour dot and name on a tinted capsule. The name stays in Pond ink so it reads on every hue.
struct SpeakerChip: View {
    let name: String
    let colorIndex: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let hue = SpeakerPalette.color(colorIndex)
        HStack(spacing: 6) {
            Circle().fill(hue).frame(width: 8, height: 8)
            Text(name).font(.subheadline.weight(.medium)).foregroundStyle(Color.chirp.ink).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(hue.opacity(scheme == .dark ? SpeakerPalette.tint.dark : SpeakerPalette.tint.light), in: Capsule())
        .contentShape(Capsule())
    }
}

/// One labelled segment: a chip, then the words, for each turn. Tapping a chip opens its menu.
struct SpeakerTurnsView: View {
    @ObservedObject var notes: LiveNotesController
    let segment: NotesSegment
    let segmentIndex: Int
    let showRaw: Bool
    let clock: (TimeInterval) -> String
    let rename: (Int) -> Void

    var body: some View {
        let roster = notes.document.roster
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array((segment.turns ?? []).enumerated()), id: \.offset) { turnIndex, turn in
                let menu = SpeakerFixups.menu(for: turn.person, in: roster)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Menu {
                            Button("Rename “\(menu.name)”…", systemImage: "pencil") { rename(turn.person) }
                                .accessibilityIdentifier("chirp.notes.speaker.rename")
                            if !menu.mergeTargets.isEmpty {
                                Menu("Same person as", systemImage: "person.2") {
                                    ForEach(menu.mergeTargets, id: \.self) { id in
                                        Button(roster.displayName(id)) { notes.mergeSpeaker(turn.person, into: id) }
                                    }
                                }.accessibilityIdentifier("chirp.notes.speaker.merge")
                            }
                            ForEach(menu.separable, id: \.self) { id in
                                Button("Separate “\(roster.person(id: id)?.name ?? "Person \(id)")”", systemImage: "person.badge.minus") {
                                    notes.separateSpeaker(id)
                                }.accessibilityIdentifier("chirp.notes.speaker.separate")
                            }
                        } label: {
                            SpeakerChip(name: menu.name, colorIndex: roster.colorIndex(turn.person))
                        }
                        .accessibilityLabel(menu.name).accessibilityHint("Rename, merge or separate this speaker")
                        .accessibilityIdentifier("chirp.notes.speaker.chip.\(segmentIndex).\(turnIndex)")
                        if turnIndex > 0 {
                            Text(clock(turn.start)).font(ChirpType.timer(.caption)).foregroundStyle(Color.chirp.inkMuted)
                        }
                    }
                    Text(showRaw ? turn.raw : turn.text).textSelection(.enabled)
                        .accessibilityIdentifier("chirp.notes.speaker.text.\(segmentIndex).\(turnIndex)")
                }
            }
        }
    }
}

/// Rename a person everywhere in the note; blank goes back to "Person N". Offers to replace the old name in the notes too.
struct RenameSpeakerSheet: View {
    @ObservedObject var notes: LiveNotesController
    let person: Int
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var replace = true
    @FocusState private var focused: Bool

    var body: some View {
        let roster = notes.document.roster
        let old = roster.displayName(person)
        let offer = SpeakerFixups.replaceOffer(person, renamingTo: name, in: notes.document)
        NavigationStack {
            Form {
                Section {
                    TextField("Person \(roster.resolve(person))", text: $name).focused($focused)
                        .textInputAutocapitalization(.words).autocorrectionDisabled().submitLabel(.done)
                        .onSubmit(commit).accessibilityIdentifier("chirp.notes.speaker.name")
                        .onChange(of: name) { _, value in if value.count > SpeakerFixups.maxNameLength { name = String(value.prefix(SpeakerFixups.maxNameLength)) } }
                } header: { Text("Name") } footer: {
                    Text("Used everywhere in this note: the transcript, the notes Chirp writes and exports.")
                }
                if let offer {
                    Section {
                        Toggle("Also replace “\(offer.old)” with “\(offer.new)” in the notes (\(offer.count == 1 ? "1 place" : "\(offer.count) places"))",
                               isOn: $replace).accessibilityIdentifier("chirp.notes.speaker.replace")
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Color.chirp.background)
            .navigationTitle("Rename “\(old)”").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Rename", action: commit).accessibilityIdentifier("chirp.notes.speaker.confirm") }
            }
        }
        .tint(Color.chirp.koi).presentationDetents([.medium])
        .onAppear { name = roster.person(id: roster.resolve(person))?.name ?? ""; focused = true }
    }

    private func commit() {
        let offer = SpeakerFixups.replaceOffer(person, renamingTo: name, in: notes.document)
        notes.renameSpeaker(person, to: name, replaceInNotes: replace && offer != nil)
        dismiss()
    }
}

extension View {
    /// Before the Mac's one download: what it is, where it comes from, and what happens to voices.
    func speakerConsentAlert(_ notes: LiveNotesController, isPresented: Bool) -> some View {
        alert(SpeakerNotice.consentTitle, isPresented: Binding(get: { isPresented }, set: { if !$0 { notes.dismissSpeakerConsent() } })) {
            Button("Download") { notes.confirmSpeakerDownload() }.accessibilityIdentifier("chirp.notes.speaker.download")
            Button("Not now", role: .cancel) { notes.dismissSpeakerConsent() }
        } message: { Text(SpeakerNotice.consentMessage) }
    }
}
