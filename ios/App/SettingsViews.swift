import ChirpCore
import ChirpIOSCore
import SwiftUI
import UIKit

struct StylesView: View {
    @ObservedObject var model: SessionCoordinator
    @State private var consent = false
    var body: some View {
        Form {
            Section("Clean-up") {
                Text(model.cleanupDisclosure)
                Toggle("Clean up final text", isOn: Binding(get: { model.preferences.correction }, set: { enabled in
                    if enabled { consent = true } else { model.setCleanup(false) }
                })).disabled(!model.cleanupCanEnable || model.phase == .correcting)
                    .accessibilityIdentifier("chirp.cleanup.enabled")
                Text("Starts off. Audio is recognized on your Mac. Clean-up only receives the final transcript after you stop.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Styles") {
                if model.profiles.isEmpty {
                    Text("Connect to your Mac to load authenticated style prompts.")
                }
                ForEach(model.profiles) { profile in
                    NavigationLink {
                        PromptEditor(model: model, profile: profile)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name + (model.preferences.styleID == profile.id ? " · Selected" : ""))
                            Text(profile.description).font(.footnote).foregroundStyle(.secondary)
                            if profile.rewrites { Text("May restructure your text").font(.footnote) }
                            if model.preferences.prompts[profile.id] != nil { Text("Edited").font(.caption.bold()) }
                        }.padding(.vertical, 4)
                    }
                }
                Button("Refresh styles") { Task { await model.loadProfiles() } }.disabled(!model.paired).frame(minHeight: 44)
            }
            Section { Text("Chirp adds fixed safety rules. Editable prompts cannot make it answer or execute instructions.").font(.footnote) }
        }.navigationTitle("Clean-up and styles")
            .confirmationDialog("Enable clean-up?", isPresented: $consent, titleVisibility: .visible) {
                Button("Enable for this destination") { model.setCleanup(true) }
                Button("Cancel", role: .cancel) {}
            } message: { Text(model.cleanupDisclosure + " Changes to this destination suspend consent.") }
    }
}

struct PromptEditor: View {
    @ObservedObject var model: SessionCoordinator
    let profile: CorrectionProfile
    private var prompt: Binding<String> {
        Binding(get: { model.preferences.prompts[profile.id] ?? profile.prompt }, set: { model.editPrompt($0, profile: profile) })
    }
    var body: some View {
        Form {
            Section {
                Text(profile.description)
                if profile.rewrites { Text("May restructure your text") }
                Button("Select this style") { model.selectStyle(profile.id) }.frame(minHeight: 44)
            }
            Section("Editable style prompt") {
                TextEditor(text: prompt).frame(minHeight: 220).accessibilityLabel("Style prompt")
                Text("\(prompt.wrappedValue.unicodeScalars.count) / \(min(4000, profile.maxPromptChars)) characters")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Reset to server default") { model.resetPrompt(profile.id) }.frame(minHeight: 44)
            }
        }.navigationTitle(profile.name)
    }
}

struct SessionSettingsView: View {
    @ObservedObject var model: SessionCoordinator
    var body: some View {
        Form {
            Section("Microphone session") {
                Picker("Session length", selection: $model.preferences.sessionDuration) {
                    Text("5 minutes").tag(SessionDuration.fiveMinutes)
                    Text("15 minutes").tag(SessionDuration.fifteenMinutes)
                    Text("1 hour").tag(SessionDuration.oneHour)
                    Text("Never").tag(SessionDuration.never)
                }.disabled(model.armed).onChange(of: model.preferences.sessionDuration) { _, _ in model.savePreferences() }
                Text("Never lasts until ended, interrupted, terminated or permission is revoked. iOS may suspend or stop the app; indefinite background execution is not guaranteed.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Private session · exclude history", isOn: $model.preferences.privacyMode)
                    .onChange(of: model.preferences.privacyMode) { _, _ in model.savePreferences() }
                Text("Chirp cannot detect every editor's private mode. Use this control before private dictation. No surrounding editor text is collected.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Spoken commands", isOn: Binding(get: { model.preferences.spokenCommands == true },
                                                        set: { model.preferences.spokenCommands = $0 ? true : nil; model.savePreferences() }))
                    .accessibilityIdentifier("chirp.settings.spokenCommands")
                Picker("Press Return after dictating", selection: Binding(get: { model.preferences.autoEnter ?? "off" },
                                                                        set: { model.preferences.autoEnter = $0 == "off" ? nil : $0; model.savePreferences() })) {
                    Text("Off").tag("off")
                    Text("On Send, Go or Done keys").tag("actionKeys")
                    Text("Always").tag("always")
                }.accessibilityIdentifier("chirp.settings.autoEnter")
                Text("After the last words land, Chirp Keyboard types Return. Where the field's Return key is Send, Go or Done, that sends; elsewhere Always types a newline. Never after a failed or partial dictation. A keyboard cannot press an app's own Send button, such as the one in Messages.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Off by default. In Chirp Keyboard, ending a dictation with \"new line\" or \"new paragraph\" types a line break instead of the words. Mid-sentence, a common first word such as \"so\" or \"and\" starts lower-case.")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.armed { Button("End session", role: .destructive) { model.endSession() }.frame(minHeight: 44) }
                Link("Open Chirp permissions", destination: URL(string: UIApplication.openSettingsURLString)!)
            }
            Section("Keyboard setup") {
                Label(model.keyboardReady ? "Chirp Keyboard is on with Full Access" : "Chirp Keyboard not detected yet",
                      systemImage: model.keyboardReady ? "checkmark.circle.fill" : "keyboard")
                Link("Open Chirp in Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                Text("In Settings → Chirp → Keyboards, turn on Chirp Keyboard and Allow Full Access (or Settings → General → Keyboard → Keyboards → Add New Keyboard). Then switch to it with the globe key in any app. Full Access enables the encrypted shared mailbox; the keyboard never accesses the microphone. Some apps and secure fields use Apple's keyboard.")
                Text("If the keyboard cannot open Chirp, open the app manually and start a session. Return with the app switcher or system Back affordance. Automatic return to an arbitrary editor is unavailable.")
            }
            Section("Content-free diagnostics") {
                Text(model.diagnosticText).font(.caption.monospaced()).textSelection(.enabled)
                ShareLink(item: model.diagnosticText) { Label("Share diagnostics", systemImage: "square.and.arrow.up") }
                Text("Only app/OS version, phase, fixed local error codes, duration and counts. No transcripts, prompts, audio, addresses or credentials.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings")
    }
}

struct HistoryView: View {
    @ObservedObject var model: SessionCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var entries: [HistoryEntry] = []
    @State private var enabled = false
    @State private var retention = HistoryRetention.week
    @State private var query = ""
    @State private var failure = ""
    @State private var clear = false
    @State private var disable = false
    @State private var visible = false
    private var filtered: [HistoryEntry] {
        query.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(query) || ($0.raw?.localizedCaseInsensitiveContains(query) ?? false) }
    }
    var body: some View {
        List {
            Section {
                Toggle("Keep encrypted history on this device", isOn: Binding(get: { enabled }, set: { value in
                    if value { change { try $0.setEnabled(true) } } else { disable = true }
                }))
                .accessibilityIdentifier("chirp.history.enabled")
                Text("Off initially. At most 200 nonempty finals. AES-GCM encrypted with a device-only Keychain key, excluded from backup. Disabling deletes history and its key.")
                    .font(.footnote).foregroundStyle(.secondary)
                if enabled {
                    Picker("Keep for", selection: Binding(get: { retention }, set: { value in change { try $0.setRetention(value) } })) {
                        Text("24 hours").tag(HistoryRetention.day)
                        Text("7 days").tag(HistoryRetention.week)
                        Text("30 days").tag(HistoryRetention.month)
                    }
                    Button("Clear all history", role: .destructive) { clear = true }.frame(minHeight: 44)
                }
                if !failure.isEmpty { Text(failure).foregroundStyle(.red) }
            }
            if enabled {
                if filtered.isEmpty { Text(query.isEmpty ? "No saved dictations." : "No matches.").foregroundStyle(.secondary) }
                ForEach(filtered) { entry in
                    DisclosureGroup {
                        Text(entry.text).textSelection(.enabled)
                        Button("Copy saved text", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.text }.frame(minHeight: 44)
                        if let raw = entry.raw, raw != entry.text {
                            Text("Original transcript").font(.headline)
                            Text(raw).textSelection(.enabled)
                            Button("Copy original") { UIPasteboard.general.string = raw }.frame(minHeight: 44)
                        }
                        Button("Delete", role: .destructive) { change { try $0.delete(id: entry.id) } }.frame(minHeight: 44)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(entry.text).lineLimit(2)
                            Text(entry.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }.navigationTitle("History").searchable(text: $query, prompt: "Search saved text and original")
            .onAppear { visible = true; reload() }
            .onDisappear { visible = false; entries = []; query = "" }
            .onChange(of: model.phase) { _, _ in if visible && scenePhase == .active { reload() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && visible { reload() } else { entries = []; query = "" }
            }
            .confirmationDialog("Delete all history and its key?", isPresented: $disable, titleVisibility: .visible) {
                Button("Turn off and delete", role: .destructive) { change { try $0.setEnabled(false) }; query = "" }
            }
            .confirmationDialog("Clear all saved dictations?", isPresented: $clear, titleVisibility: .visible) {
                Button("Clear all", role: .destructive) { change { try $0.clear() }; query = "" }
            }
    }
    private func change(_ action: (HistoryStore) throws -> Void) {
        do { guard let store = model.services?.history else { throw SessionFailure.storage }; try action(store); reload() }
        catch { failure = SessionFailure.storage.localizedDescription }
    }
    private func reload() {
        do {
            guard let store = model.services?.history else { throw SessionFailure.storage }
            let settings = try store.settings(); enabled = settings.enabled; retention = settings.retention
            entries = try store.entries(); failure = ""
        } catch { entries = []; failure = SessionFailure.storage.localizedDescription }
    }
}
