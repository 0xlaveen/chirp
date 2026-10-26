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
        Form {
            Section {
                Toggle("Remember voices of people I name", isOn: Binding(get: { notes.savedVoices?.enabled == true }, set: { on in
                    if on { action(.enable) } else { disabling = true }
                })).disabled(notes.savedVoices == nil || notes.voicesBusy)
                    .accessibilityIdentifier("chirp.notes.voices.enabled")
            } footer: {
                Text("Chirp recognises these people in new notes on all your devices. They’re kept on your paired computer, never uploaded. This switch applies to every device paired to this computer.")
            }
            if let error = notes.voicesError {
                Section { Text(error).foregroundStyle(Color.chirp.record).accessibilityIdentifier("chirp.notes.voices.error") }
            }
            if let library = notes.savedVoices {
                Section {
                    if library.voices.isEmpty {
                        Text("Name a speaker in a note and Chirp will recognise them next time.")
                            .foregroundStyle(Color.chirp.inkMuted).accessibilityIdentifier("chirp.notes.voices.empty")
                    }
                    ForEach(library.voices) { voice in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(voice.name).font(.headline)
                                Text(detail(voice)).font(.caption).foregroundStyle(Color.chirp.inkMuted)
                                if !voice.compatible { Text("Name them again to keep recognising this voice").font(.caption) }
                            }
                            Spacer()
                            Menu {
                                Button("Rename…", systemImage: "pencil") { name = voice.name; renaming = voice }
                                Button("Forget…", systemImage: "trash", role: .destructive) { forgetting = voice }
                            } label: { Label("Voice actions", systemImage: "ellipsis.circle") }.labelStyle(.iconOnly)
                                .accessibilityIdentifier("chirp.notes.voices.menu.\(voice.id)")
                        }
                    }
                }.disabled(notes.voicesBusy)
                if !library.voices.isEmpty {
                    Section { Button("Forget all voices…", role: .destructive) { forgettingAll = true }
                        .accessibilityIdentifier("chirp.notes.voices.forgetAll") }.disabled(notes.voicesBusy)
                }
            } else if !notes.voicesAvailable {
                Text("Update Chirp on your computer to save voices")
            } else if notes.voicesError == nil { ProgressView("Loading saved voices…") }
            Button("Refresh saved voices") { Task { await notes.refreshHealth() } }.disabled(notes.voicesBusy)
        }.scrollContentBackground(.hidden).background(Color.chirp.background).tint(Color.chirp.koi)
            .navigationTitle("Saved voices").navigationBarTitleDisplayMode(.inline)
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
            .confirmationDialog("Forget saved voices?", isPresented: Binding(get: { forgetting != nil || forgettingAll }, set: { if !$0 { forgetting = nil; forgettingAll = false } }), titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    if let voice = forgetting { action(.forget(voice: voice.id)) } else { action(.forgetAll) }
                    forgetting = nil; forgettingAll = false
                }
            } message: { Text("Removes \(forgetting?.name ?? "all saved voices") from your computer for every device. Names in existing notes stay. This cannot be undone.") }
    }

    private func action(_ value: VoiceLibraryAction) { Task { await notes.changeSavedVoices(value) } }
    private func detail(_ voice: SavedVoice) -> String {
        "Saved \(voice.created.formatted(date: .abbreviated, time: .omitted))"
            + (voice.updated == voice.created ? "" : " · updated \(voice.updated.formatted(date: .abbreviated, time: .omitted))")
            + " · \(Int(voice.seconds)) s"
    }
}
