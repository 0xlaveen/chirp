import ChirpCore
import ChirpIOSCore
import SwiftUI

/// The server's library, read afresh on entry. No local cache or voiceprint storage.
struct SavedVoicesView: View {
    @ObservedObject var notes: LiveNotesController
    @State private var disabling = false
    @State private var forgettingAll = false
    @State private var forgetting: SavedVoice?
    @State private var renaming: SavedVoice?
    @State private var name = ""

    var body: some View {
        SettingsPageScroll {
            SettingsGroup {
                SwitchRow(title: "Remember voices of people I name", isOn: notes.savedVoices?.enabled == true,
                          summary: "Every device paired to this computer", symbol: "person.wave.2",
                          infoTitle: "Saved voices",
                          infoBody: "Chirp recognises these people in new notes on all your devices. They’re kept on your paired computer, never uploaded. This switch applies to every device paired to this computer.",
                          identifier: "chirp.notes.voices.enabled", disabled: notes.savedVoices == nil || notes.voicesBusy,
                          set: { on in if on { action(.enable) } else { disabling = true } })
            }
            if let error = notes.voicesError {
                Text(error).font(.footnote).foregroundStyle(Color.chirp.record).accessibilityIdentifier("chirp.notes.voices.error")
            }
            if let library = notes.savedVoices {
                SettingsGroup(title: "Voices") {
                    if library.voices.isEmpty {
                        SettingsItem {
                            Text("Name a speaker in a note and Chirp will recognise them next time.")
                                .font(.subheadline).foregroundStyle(Color.chirp.inkMuted).accessibilityIdentifier("chirp.notes.voices.empty")
                        }
                    }
                    ForEach(library.voices) { voice in
                        RowTile(hasSummary: true) {
                            RowText(title: voice.name, summary: detail(voice) + (voice.compatible ? "" : " · Name them again to keep recognising this voice"))
                            Spacer(minLength: 0)
                            Menu {
                                Button("Rename…", systemImage: "pencil") { name = voice.name; renaming = voice }
                                Button("Forget…", systemImage: "trash", role: .destructive) { forgetting = voice }
                            } label: {
                                Image(systemName: "ellipsis.circle").font(.title3).frame(minWidth: 44, minHeight: 44)
                            }.accessibilityLabel("Voice actions").accessibilityIdentifier("chirp.notes.voices.menu.\(voice.id)")
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                        }
                    }
                }.disabled(notes.voicesBusy)
            } else if !notes.voicesAvailable {
                Text("Update Chirp on your computer to save voices").font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
            } else if notes.voicesError == nil { ProgressView("Loading saved voices…").frame(maxWidth: .infinity) }
            // The destructive action comes last (#271 2.6).
            SettingsGroup {
                ActionRow(title: "Refresh saved voices", symbol: "arrow.clockwise", disabled: notes.voicesBusy) {
                    Task { await notes.refreshHealth() }
                }
                if notes.savedVoices?.voices.isEmpty == false {
                    ActionRow(title: "Forget all voices…", symbol: "trash", destructive: true, disabled: notes.voicesBusy,
                              identifier: "chirp.notes.voices.forgetAll") { forgettingAll = true }
                }
            }
        }.tint(Color.chirp.koi)
            .navigationTitle("Saved voices")
            .task { await notes.refreshHealth() }
            .refreshable { await notes.refreshSavedVoices() }
            .confirmationDialog("Stop remembering voices?", isPresented: $disabling, titleVisibility: .visible) {
                Button("Turn off and forget", role: .destructive) { action(.disable(forget: true)) }
                Button("Keep voices") { action(.disable(forget: false)) }
            } message: { Text("Stops saving and recognising on every device. Also forget \(notes.savedVoices?.voices.count ?? 0) saved voices?") }
            .alert("Rename saved voice", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name).accessibilityIdentifier("chirp.notes.voices.rename.name")
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    if let voice = renaming, let cleaned = SpeakerFixups.cleanName(name) { action(.rename(voice: voice.id, name: cleaned)) }
                    renaming = nil
                }.disabled(!SavedVoice.isValidName(SpeakerFixups.cleanName(name) ?? ""))
            } message: { Text("Names in existing notes stay.") }
            .confirmationDialog(forgetting.map { "Forget \($0.name)?" } ?? "Forget all voices?", isPresented: Binding(get: { forgetting != nil || forgettingAll }, set: { if !$0 { forgetting = nil; forgettingAll = false } }), titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    if let voice = forgetting { action(.forget(voice: voice.id)) } else { action(.forgetAll) }
                    forgetting = nil; forgettingAll = false
                }
            } message: { Text((forgetting.map { "Removes \($0.name)’s voice" } ?? "Removes all saved voices") + " from your computer for every device. Names in existing notes stay. This can’t be undone.") }
    }

    private func action(_ value: VoiceLibraryAction) { Task { await notes.changeSavedVoices(value) } }
    private func detail(_ voice: SavedVoice) -> String {
        "Saved \(voice.created.formatted(date: .abbreviated, time: .omitted))"
            + (voice.updated == voice.created ? "" : " · updated \(voice.updated.formatted(date: .abbreviated, time: .omitted))")
            + " · \(Int(voice.seconds)) s"
    }
}
