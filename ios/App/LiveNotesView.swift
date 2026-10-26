import AVFoundation
import ChirpCore
import ChirpIOSCore
import SwiftUI
import UniformTypeIdentifiers

struct LiveNotesView: View {
    @ObservedObject var notes: LiveNotesController
    @ObservedObject var session: SessionCoordinator
    var pair: () -> Void = {}
    var dictate: () -> Void = {}
    var body: some View { NotesLibraryView(notes: notes, session: session, pair: pair, dictate: dictate) }
}

struct NoteDetailView: View {
    @ObservedObject var notes: LiveNotesController
    @ObservedObject var session: SessionCoordinator
    var pair: () -> Void
    var openRecording: () -> Void
    var deleted: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var editing = false
    @FocusState private var editorFocused: Bool
    @State private var renaming = false
    @State private var title = ""
    @State private var exporting = false
    @State private var settings = false
    @State private var transcript = false
    @State private var showRaw = false
    @State private var confirmUndo = false
    @State private var confirmSwitch = false
    @State private var namingSpeakers = false
    @State private var transcriptNamingSpeakers = false
    @State private var renamingSpeaker: SpeakerSheetItem?
    @StateObject private var player = NotesSegmentPlayer()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleBlock
                    if notes.showsNameSpeakersLine {
                        HStack {
                            Text("Who was speaking?").font(.subheadline)
                            Button("Name speakers") { namingSpeakers = true }
                                .accessibilityIdentifier("chirp.notes.speakers.name.open")
                            Spacer(minLength: 0)
                            Button("Dismiss", systemImage: "xmark") { notes.dismissSpeakerLine() }.labelStyle(.iconOnly)
                        }.padding(12).background(Color.chirp.koiContainer, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let error = notes.voicesError {
                        Text(error).font(.footnote).foregroundStyle(Color.chirp.inkMuted).accessibilityIdentifier("chirp.notes.voices.note")
                    }
                    if let banner = banner {
                        PondBanner(kind: notes.debugRetention ? .error : .info, title: banner)
                            .accessibilityElement(children: .combine).accessibilityLabel(banner)
                            .accessibilityIdentifier("chirp.notes.notice")
                    }
                    if let status = notes.speakerStatus { SpeakerStatusLine(notes: notes, status: status) }
                    HStack(spacing: 12) {
                        Button("Transcript", systemImage: "text.alignleft") { transcript.toggle() }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule)
                            .keyboardShortcut("t", modifiers: [.command, .option])
                            .accessibilityIdentifier("chirp.notes.transcript.open")
                        if notes.selectedAudioBytes > 0 {
                            Label(size(notes.selectedAudioBytes), systemImage: "waveform").font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                        }
                    }
                    if editing {
                        TextEditor(text: Binding(get: { notes.document.text }, set: { notes.edit($0) }))
                            .font(.body).scrollContentBackground(.hidden).frame(minHeight: 420)
                            .focused($editorFocused).accessibilityIdentifier("chirp.notes.editor")
                    } else if notes.document.text.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(notes.state.isActive ? "A little room for your thoughts" : "Make this note your own").font(ChirpType.h2)
                            Text(notes.structuring.isOff ? "Your transcript appears as you speak. Tap Edit to add your own notes." : "Chirp turns what you say into notes. You can edit them at any time.")
                                .foregroundStyle(Color.chirp.inkMuted)
                        }.padding(.vertical, 24)
                    } else {
                        NotesBlocksView(text: notes.document.text, title: notes.document.title, toggleTask: toggleTask)
                            .textSelection(.enabled).accessibilityElement(children: .contain).accessibilityIdentifier("chirp.notes.preview")
                    }
                    if !notes.document.livePartial.isEmpty {
                        Divider()
                        Text(notes.document.livePartial).italic().foregroundStyle(Color.chirp.inkMuted)
                            .accessibilityIdentifier("chirp.notes.partial")
                    }
                    if notes.canUndoOrganize {
                        HStack {
                            Label("Notes organized", systemImage: "sparkles").font(.footnote).foregroundStyle(Color.chirp.moon)
                            Spacer()
                            Button("Undo Organize") { if !notes.undoOrganize() { confirmUndo = true } }
                                .font(.footnote).accessibilityIdentifier("chirp.notes.undo")
                        }.padding(12).background(Color.chirp.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(24).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.background(Color.chirp.surface)
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline).tint(Color.chirp.koi)
        .safeAreaInset(edge: .bottom) { dock.padding(.horizontal, 16).padding(.vertical, 12).background(Color.chirp.background) }
        .toolbar { toolbar }
        .inspector(isPresented: Binding(get: { transcript && sizeClass == .regular }, set: { transcript = $0 })) {
            transcriptContent.inspectorColumnWidth(min: 280, ideal: 330, max: 420)
        }
        .sheet(isPresented: Binding(get: { transcript && sizeClass != .regular }, set: { transcript = $0 })) {
            NavigationStack {
                transcriptContent.navigationTitle("Transcript").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { transcript = false } } }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $namingSpeakers) { NameSpeakersSheet(notes: notes) }
        .alert("Remembering voices", isPresented: Binding(get: { notes.rememberedVoiceNotice != nil }, set: { if !$0 { notes.rememberedVoiceNotice = nil } })) {
            Button("OK") { notes.rememberedVoiceNotice = nil }
            Button("Don’t remember voices", role: .destructive) {
                notes.rememberedVoiceNotice = nil
                Task { await notes.changeSavedVoices(.disable(forget: false)) }
            }
        } message: { Text("Chirp will recognise \(notes.rememberedVoiceNotice ?? "this person")’s voice in later notes on your devices. Saved voices stay on your Mac. Settings → Notes → Saved voices.") }
        .sheet(isPresented: $settings) { NotesSettingsSheet(notes: notes) }
        .fileExporter(isPresented: $exporting, document: NotesMarkdownFile(text: notes.markdown), contentType: NotesMarkdownFile.markdown,
                      defaultFilename: notes.exportName) { if case .success = $0 { notes.didExport() } }
        .confirmationDialog("Undo Organize?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Restore notes before Organize", role: .destructive) { notes.undoOrganize(confirmed: true) }
        } message: { Text("You edited the notes since Organize. Restoring replaces those edits too.") }
        .confirmationDialog("Another note is recording", isPresented: $confirmSwitch, titleVisibility: .visible) {
            Button("Stop current and continue here") { Task { await notes.stopAndContinue() } }
            Button("Go to recording", action: openRecording)
        }
        .task(id: notes.document.id) { player.stop(); editing = false; await notes.refreshAudio() }
        .onChange(of: notes.totalAudioBytes) { _, _ in Task { await notes.refreshAudio() } }
        .onChange(of: editing) { _, value in notes.setEditing(value); editorFocused = value }
        .onDisappear { player.stop(); notes.setEditing(false); Task { await notes.settleJournal() } }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if renaming {
                TextField("Note title", text: $title).font(ChirpType.noteTitle).submitLabel(.done)
                    .onSubmit { renaming = false; Task { await notes.rename(title) } }
                    .accessibilityIdentifier("chirp.notes.title.editor")
                Button("Done") { renaming = false; Task { await notes.rename(title) } }
            } else {
                Button { title = notes.document.title; renaming = true } label: {
                    Text(notes.document.title).font(ChirpType.noteTitle).foregroundStyle(Color.chirp.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityLabel("Rename \(notes.document.title)").accessibilityIdentifier("chirp.notes.title")
            }
            HStack(spacing: 8) {
                Text(notes.statusLine).accessibilityIdentifier("chirp.notes.status").accessibilityAddTraits(.updatesFrequently)
                if notes.elapsed > 0 || notes.state.isActive {
                    Text("·")
                    Text(clock(notes.elapsed)).monospacedDigit().accessibilityIdentifier("chirp.notes.elapsed")
                }
            }.font(.subheadline).foregroundStyle(notes.state.isCapturing ? Color.chirp.record : .chirp.inkMuted)
        }
    }

    private var banner: String? {
        if notes.debugRetention { return "DEBUG: Mac keeps recordings" }
        if !notes.notice.isEmpty { return notes.notice }
        if session.armed && !notes.isActive { return "End the keyboard session before recording notes." }
        return notes.detailLine
    }

    private var dock: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { dockButtons }
            VStack(spacing: 12) { dockButtons }
        }.padding(16).frame(maxWidth: 680).background(.regularMaterial, in: RoundedRectangle(cornerRadius: typeSize.isAccessibilitySize ? 24 : 40))
            .modifier(NotesDockGlass())
    }

    @ViewBuilder private var dockButtons: some View {
        if notes.state.isLive {
            HStack(spacing: 8) {
                Ripple(level: notes.state.isCapturing ? 0.3 : 0, reduceMotion: notes.isPaused ? true : nil).frame(width: 32, height: 32)
                Text(clock(notes.elapsed)).font(ChirpType.timer(.headline))
            }.accessibilityHidden(true)
            Button(notes.isPaused ? "Resume" : "Pause", systemImage: notes.isPaused ? "mic.fill" : "pause.fill") { Task { await notes.togglePause() } }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).keyboardShortcut("p", modifiers: [.command, .shift])
                .accessibilityIdentifier("chirp.notes.pause")
            Button("Stop", systemImage: "stop.fill") { Task { await notes.stop() } }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Color.chirp.record).foregroundStyle(Color.chirp.onKoi)
                .keyboardShortcut("r", modifiers: [.command, .shift]).accessibilityIdentifier("chirp.notes.stop")
        } else if notes.state == .stopping {
            ProgressView("Finishing…").accessibilityIdentifier("chirp.notes.finishing")
        } else {
            if !notes.paired {
                Button("Pair Mac", systemImage: "qrcode.viewfinder", action: pair).buttonStyle(.bordered).accessibilityIdentifier("chirp.notes.pair")
            }
            Button(notes.document.sessions.isEmpty && notes.document.segments.isEmpty && notes.elapsed == 0 ? "Record" : "Continue recording", systemImage: "record.circle") {
                player.stop()
                if notes.isActive { confirmSwitch = true } else { Task { await notes.record() } }
            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Color.chirp.koi).foregroundStyle(Color.chirp.onKoi)
                .disabled(!notes.paired || notes.starting || session.armed)
                .keyboardShortcut("r", modifiers: [.command, .shift]).accessibilityIdentifier("chirp.notes.record")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if let id = notes.recordingID, id != notes.document.id {
                Button(action: openRecording) { Label("Recording · \(notes.recordingTitle) · \(clock(notes.recordingElapsed))", systemImage: "record.circle.fill").lineLimit(1) }
                    .font(.caption.monospacedDigit()).tint(Color.chirp.record).accessibilityIdentifier("chirp.notes.jumpRecording")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(editing ? "Done" : "Edit", systemImage: editing ? "checkmark" : "pencil") { editing.toggle() }
                .accessibilityIdentifier("chirp.notes.edit")
            Button("Organize", systemImage: "sparkles") { notes.organize() }.tint(Color.chirp.moon)
                .disabled(!notes.canOrganize).accessibilityIdentifier("chirp.notes.organize")
            Menu {
                Button("Copy", systemImage: "doc.on.doc") { notes.copy() }.accessibilityIdentifier("chirp.notes.copy")
                ShareLink(item: notes.markdown, subject: Text(notes.document.title)) { Label("Share…", systemImage: "square.and.arrow.up") }
                Button("Export Markdown…", systemImage: "square.and.arrow.up") { exporting = true }.accessibilityIdentifier("chirp.notes.save")
                Button("Rename", systemImage: "pencil") { title = notes.document.title; renaming = true }
                if notes.speakersAvailable {
                    Divider()
                    Toggle("Label speakers", systemImage: "person.2", isOn: Binding(get: { notes.labelSpeakers }, set: { notes.setLabelSpeakers($0) }))
                        .accessibilityIdentifier("chirp.notes.speakers.toggle")
                }
                Divider()
                Button("Notes settings", systemImage: "gearshape") { settings = true }.accessibilityIdentifier("chirp.notes.settings")
                if notes.selectedAudioBytes > 0 { Button("Delete audio (\(size(notes.selectedAudioBytes)))", systemImage: "waveform.slash", role: .destructive) { player.stop(); Task { await notes.deleteAudio(); await notes.refreshAudio() } } }
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await notes.delete([notes.document.id]); deleted() } }.disabled(notes.document.id == notes.recordingID)
            } label: { Label("More", systemImage: "ellipsis.circle") }.accessibilityIdentifier("chirp.notes.export")
        }
    }

    private var transcriptContent: some View {
        VStack(spacing: 0) {
            if !notes.document.namableSpeakers.isEmpty {
                Button("Name speakers", systemImage: "person.2") { if sizeClass == .regular { namingSpeakers = true } else { transcriptNamingSpeakers = true } }
                    .padding().accessibilityIdentifier("chirp.notes.speakers.name.header")
            }
            Toggle("Show raw", isOn: $showRaw).padding().accessibilityIdentifier("chirp.notes.raw")
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if notes.document.segments.isEmpty { Text("The transcript appears here, segment by segment.").foregroundStyle(Color.chirp.inkMuted) }
                    ForEach(Array(notes.document.segments.enumerated()), id: \.element.id) { index, segment in
                        ForEach(Array(notes.document.sessions.dropFirst().enumerated()), id: \.offset) { _, boundary in
                            if boundary.firstSegment == index {
                                HStack { Divider(); Text("Continued · \(boundary.startedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(Color.chirp.inkMuted); Divider() }.padding(.vertical, 8)
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(clock(segment.offset)).font(ChirpType.timer(.caption)).foregroundStyle(Color.chirp.inkMuted)
                                Spacer()
                                if notes.hasAudio(index) {
                                    Button(player.segment == index ? "Stop replay" : "Play segment", systemImage: player.segment == index ? "stop.fill" : "play.fill") {
                                        if player.segment == index { player.stop() }
                                        else {
                                            let request = player.beginLoading(), id = notes.document.id
                                            Task {
                                                do {
                                                    let data = try await notes.audioData(segment: index)
                                                    guard notes.document.id == id, player.accepts(request), !notes.isActive, !session.armed else { return }
                                                    if let data { player.play(data, segment: index) } else { player.failed() }
                                                } catch { if player.accepts(request) { player.failed() } }
                                            }
                                        }
                                    }.font(.caption).buttonStyle(.bordered).buttonBorderShape(.capsule)
                                        .disabled(notes.isActive || session.armed)
                                        .accessibilityHint(notes.isActive || session.armed ? "Stop recording to replay kept audio" : "Plays this speech segment")
                                        .accessibilityIdentifier("chirp.notes.play.\(index)")
                                }
                            }
                            if let failure = segment.failure {
                                Label("Not transcribed (\(failure))", systemImage: "exclamationmark.triangle").foregroundStyle(Color.chirp.record)
                            } else if let turns = segment.turns, !turns.isEmpty {
                                SpeakerTurnsView(notes: notes, segment: segment, segmentIndex: index, showRaw: showRaw, clock: clock) {
                                    renamingSpeaker = SpeakerSheetItem(id: $0)
                                } nameAll: { if sizeClass == .regular { namingSpeakers = true } else { transcriptNamingSpeakers = true } }
                            } else {
                                Text(showRaw ? segment.raw : segment.text).textSelection(.enabled)
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(player.segment == index ? Color.chirp.koiContainer : .chirp.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let error = player.error { Text(error).font(.footnote).foregroundStyle(Color.chirp.record) }
                }.padding(16)
            }.accessibilityIdentifier("chirp.notes.transcript")
        }.background(Color.chirp.background).tint(Color.chirp.koi)
            .sheet(isPresented: $transcriptNamingSpeakers) { NameSpeakersSheet(notes: notes) }
            .sheet(item: $renamingSpeaker) { RenameSpeakerSheet(notes: notes, person: $0.id) }
    }

    private func toggleTask(_ index: Int) {
        var lines = notes.document.text.components(separatedBy: "\n")
        guard lines.indices.contains(index), let box = lines[index].range(of: #"\[[ xX]\]"#, options: .regularExpression) else { return }
        lines[index].replaceSubrange(box, with: lines[index][box] == "[ ]" ? "[x]" : "[ ]")
        notes.edit(lines.joined(separator: "\n"))
    }
    private func clock(_ value: TimeInterval) -> String { ChirpNotesActivityAttributes.ContentState.clock(value) }
    private func size(_ value: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
}

private struct SpeakerSheetItem: Identifiable { let id: Int }

private struct NotesDockGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.glassEffect(.regular, in: .rect(cornerRadius: 32)) }
        else { content }
    }
}

/// Replay decrypts into memory and never writes a plaintext playback file.
@MainActor
final class NotesSegmentPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var segment: Int?
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var request = 0
    func beginLoading() -> Int { stop(); error = nil; return request }
    func accepts(_ value: Int) -> Bool { request == value }
    func failed() { stop(); error = "This audio could not be played. Try another segment." }
    func play(_ data: Data, segment: Int, offset: TimeInterval = 0) {
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: data)
            self.player = player; player.delegate = self; player.currentTime = offset
            guard player.play() else { throw SessionFailure.audio }
            self.segment = segment
        } catch { failed() }
    }
    func stop() { request += 1; player?.stop(); player = nil; segment = nil }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // AVAudioPlayer is not Sendable on older SDKs; only its identity crosses the actor boundary.
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            if self.player.map(ObjectIdentifier.init) == finished { self.stop() }
        }
    }
}

struct NotesMarkdownFile: FileDocument {
    static let markdown = UTType(filenameExtension: "md") ?? .plainText
    static var readableContentTypes: [UTType] { [markdown] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

/// Embeddable Settings → Notes form; its caller owns navigation and dismissal.
struct NotesSettingsView: View {
    @ObservedObject var notes: LiveNotesController
    @State private var confirmDeleteAudio = false
    var body: some View {
        Form {
            Section {
                Toggle("Structure notes", isOn: Binding(get: { notes.preferences.structureEnabled(health: notes.health) }, set: { notes.setStructure($0) }))
                    .disabled(!notes.structureCanEnable).accessibilityIdentifier("chirp.notes.structure")
                Toggle("Organize automatically", isOn: Binding(get: { notes.preferences.autoReorganize }, set: { notes.setAutoReorganize($0) }))
            } footer: { Text(notes.structureDisclosure) }
            Section {
                Toggle("Battery saver while locked", isOn: Binding(get: { notes.preferences.batterySaver }, set: { notes.setBatterySaver($0) }))
                    .accessibilityIdentifier("chirp.notes.batterySaver")
            } footer: { Text("Recording and structuring continue while screen updates pause.") }
            Section {
                Toggle("Keep notes on this device", isOn: Binding(get: { notes.preferences.keepNotes }, set: { notes.setKeepNotes($0) }))
                    .accessibilityIdentifier("chirp.notes.keepNotes")
                Picker("Delete notes older than", selection: Binding(get: { notes.preferences.retention }, set: { notes.setRetention($0) })) {
                    Text("Never").tag(NotesRetention.never)
                    Text("1 year").tag(NotesRetention.oneYear)
                    Text("90 days").tag(NotesRetention.ninetyDays)
                    Text("30 days").tag(NotesRetention.thirtyDays)
                }
            } footer: { Text("Notes save as you go, sealed on this device and excluded from backups. Turning this off stops keeping new changes; existing notes stay in your library. Deleted notes stay in Recently Deleted for 30 days.") }
            Section {
                Toggle("Keep audio with notes", isOn: Binding(get: { notes.preferences.keepAudio }, set: { notes.setKeepAudio($0) }))
                    .disabled(!notes.preferences.keepNotes).accessibilityIdentifier("chirp.notes.keepAudio")
                if notes.totalAudioBytes > 0 {
                    LabeledContent("Kept audio", value: ByteCountFormatter.string(fromByteCount: Int64(notes.totalAudioBytes), countStyle: .file))
                    Button("Delete kept audio", role: .destructive) { confirmDeleteAudio = true }
                }
            } footer: { Text("Off by default. Keep speech segments sealed on this device so you can replay them. Deleting audio keeps the text.") }
            Section {
                Toggle("Label speakers", isOn: Binding(get: { notes.labelSpeakers }, set: { notes.setLabelSpeakers($0) }))
                    .disabled(notes.health != nil && !notes.speakersAvailable)
                    .accessibilityIdentifier("chirp.notes.speakers.setting")
                if let status = notes.speakerModelStatus {
                    Label(status, systemImage: "person.2").font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                        .accessibilityIdentifier("chirp.notes.speakers.model")
                }
            } footer: { Text(SpeakerNotice.summary(on: notes.labelSpeakers, health: notes.health) + ". " + SpeakerNotice.info) }
            Section {
                NavigationLink("Saved voices") { SavedVoicesView(notes: notes) }
                    .disabled(!notes.voicesAvailable).accessibilityIdentifier("chirp.notes.voices.open")
            } footer: { if notes.health != nil && !notes.voicesAvailable { Text("Update Chirp on your Mac to save voices") } }

        }.scrollContentBackground(.hidden).background(Color.chirp.background).tint(Color.chirp.koi)
            .navigationTitle("Notes").task { await notes.refreshHealth() }
            .confirmationDialog("Delete all kept audio?", isPresented: $confirmDeleteAudio, titleVisibility: .visible) {
                Button("Delete kept audio", role: .destructive) { Task { await notes.deleteAudio(all: true) } }
            } message: { Text("Notes and transcripts are kept. This cannot be undone.") }
    }
}

struct NotesSettingsSheet: View {
    @ObservedObject var notes: LiveNotesController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            NotesSettingsView(notes: notes).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

extension LiveNotesController {
    var statusLine: String {
        switch state {
        case .idle: paired ? "Ready to record" : "Pair your Mac to record notes"
        case .starting: "Starting…"
        case .recording: "Recording"
        case .paused: pauseReason ?? "Paused · microphone off"
        case .stopping: "Finishing…"
        case .stopped: "Stopped"
        case .error(let message): "Stopped · \(message)"
        }
    }

    /// Structuring, Organize and the connection, one line (nil when there is nothing to say).
    var detailLine: String? {
        switch connection {
        case .offline(let kept): return "Mac offline · keeping \(ChirpNotesActivityAttributes.ContentState.clock(kept)) of audio to send later"
        case .catchingUp(let segments): return "Back online · sending \(segments) segment\(segments == 1 ? "" : "s") recorded offline"
        case .online: break
        }
        switch reorganize {
        case .organizing(let step, let of): return "Organizing · step \(step) of \(of)"
        case .running: return "Organizing…"
        case .organized(let failed, _) where failed > 0: return "Organized · \(failed) section\(failed == 1 ? "" : "s") kept as they were"
        case .conflict: return "The notes changed during Organize, so it kept your version"
        case .tooLong: return "The last section is too long to organize"
        default: break
        }
        switch structuring {
        case .running: return "Structuring on your Mac…"
        case .failed(let code): return "Structuring failed (\(code)); the next segment tries again"
        case .off(.correctionOff): return "Your Mac has clean-up off, so notes stay a transcript"
        case .off(.unsupported): return "Your Mac's chirp-server can't structure notes; update it"
        case .off(.disabled): return state.isActive ? "Structuring off · transcript only" : nil
        case .off(.waiting): return state.isActive ? "Waiting for your Mac…" : nil
        case .idle: return nil
        }
    }

    var canOrganize: Bool {
        guard state != .stopping, !document.isEmpty else { return false }
        switch reorganize {
        case .unavailable: return false
        default: return !reorganize.isRunning
        }
    }

    var exportName: String {
        "Notes " + document.startedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash)) + ".md"
    }
}
