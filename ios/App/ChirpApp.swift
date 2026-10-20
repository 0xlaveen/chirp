import ChirpIOSCore
import SwiftUI

@main
struct ChirpApp: App {
    @StateObject private var coordinator: SessionCoordinator
    @Environment(\.scenePhase) private var scenePhase
    init() {
        PrivacyController.shared.start()
        #if DEBUG
        _coordinator = StateObject(wrappedValue: ProcessInfo.processInfo.arguments.contains("--chirp-ui-test") ? SessionCoordinator.synthetic(sharedKeyboard: KeyboardTestMode.enabled) : .shared)
        #else
        _coordinator = StateObject(wrappedValue: .shared)
        #endif
    }
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if KeyboardTestMode.enabled {
                KeyboardTestHost(model: coordinator)
            } else {
                root
            }
            #else
            root
            #endif
        }
    }
    private var root: some View {
        ChirpRootView(model: coordinator)
            .onChange(of: scenePhase) { _, phase in if phase == .active { coordinator.reconcile() } }
            .onOpenURL { url in
                let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
                if c?.scheme == "chirp", c?.host == "pair" {
                    Task { await coordinator.pair(link: url.absoluteString) }
                } else if c?.scheme == "chirp", c?.host == "session", c?.path == "/start", c?.query == nil,
                          c?.fragment == nil, c?.user == nil, c?.password == nil, c?.port == nil {
                    Task { do { try await coordinator.armSession() } catch { coordinator.show(error) } }
                }
            }
    }
}

struct ChirpRootView: View {
    @ObservedObject var model: SessionCoordinator
    var body: some View {
        TabView {
            NavigationStack { DictationView(model: model) }.tabItem { Label("Dictate", systemImage: "mic") }
            NavigationStack { PairingView(model: model) }.tabItem { Label("Pair Mac", systemImage: "qrcode.viewfinder") }
            NavigationStack { StylesView(model: model) }.tabItem { Label("Styles", systemImage: "sparkles") }
            NavigationStack { HistoryView(model: model) }.tabItem { Label("History", systemImage: "clock") }
            NavigationStack { SessionSettingsView(model: model) }.tabItem { Label("Settings", systemImage: "gear") }
        }
        .safeAreaInset(edge: .bottom) {
            if model.armed {
                VStack(spacing: 8) {
                    Label("Microphone active throughout session", systemImage: "mic.fill").font(.footnote)
                    Button("End session", role: .destructive) { model.endSession() }
                        .accessibilityIdentifier("chirp.session.end")
                        .buttonStyle(.bordered).frame(minHeight: 44).keyboardShortcut("e", modifiers: [.command, .shift])
                }
                .frame(maxWidth: .infinity).padding(8).background(.regularMaterial)
            }
        }
        .overlay(alignment: .top) {
            if model.debugRetention {
                Text("DEBUG: Mac keeps recordings").font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(8).background(.red)
                    .accessibilityAddTraits(.isHeader).allowsHitTesting(false)
            }
        }
        .modifier(PrivacyShield())
    }
}

/// Cover every scene (including the scanner sheet) before iOS takes app-switcher snapshots.
struct PrivacyShield: ViewModifier {
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content.overlay {
            if phase != .active {
                ZStack {
                    Color(uiColor: .systemBackground).ignoresSafeArea()
                    Label("Chirp", systemImage: "mic").font(.largeTitle.bold())
                }.accessibilityIdentifier("privacyShield")
            }
        }
    }
}

struct DictationView: View {
    @ObservedObject var model: SessionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var active: Bool { [.connecting, .listening, .correcting].contains(model.phase) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(status, systemImage: model.armed ? "mic.fill" : "mic.slash")
                    .font(.title2.bold()).accessibilityIdentifier("sessionStatus")
                Text(model.armed ? "Idle audio is discarded immediately. Audio is sent to your paired Mac only while dictating. Return to your editor with the system app switcher to use Chirp Keyboard." : "Start a session in Chirp before using the keyboard. The microphone stays active until the session ends.")
                    .foregroundStyle(.secondary)
                if !model.armed {
                    Button("Start keyboard session") { Task { do { try await model.armSession() } catch { model.show(error) } } }
                        .buttonStyle(.bordered).disabled(!model.paired || model.working).frame(minHeight: 44)
                }
                if active {
                    Button("Stop dictation", systemImage: "stop.fill") { model.stopDictation() }
                        .accessibilityIdentifier("chirp.dictation.stop")
                        .buttonStyle(.borderedProminent).keyboardShortcut(.space, modifiers: .command).frame(minHeight: 44)
                    Button("Cancel dictation", role: .cancel) { model.cancelDictation() }
                        .buttonStyle(.bordered).keyboardShortcut(.escape, modifiers: []).frame(minHeight: 44)
                } else {
                    Button("Dictate", systemImage: "mic.fill") { Task { do { try await model.begin() } catch { model.show(error) } } }
                        .accessibilityIdentifier("chirp.dictation.start")
                        .buttonStyle(.borderedProminent).keyboardShortcut(.space, modifiers: .command)
                        .disabled(!model.paired || model.working).frame(minHeight: 44)
                }
                if !model.text.isEmpty {
                    Text(model.text).font(.title3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("transcript")
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.phase)
                }
                if model.phase == .finished {
                    ViewThatFits(in: .horizontal) {
                        HStack { resultActions }
                        VStack(alignment: .leading) { resultActions }
                    }
                    if !model.raw.isEmpty, model.raw != model.text {
                        DisclosureGroup("Original transcript") { Text(model.raw).textSelection(.enabled) }
                    }
                }
                Text(model.notice).foregroundStyle(.secondary).accessibilityIdentifier("sessionNotice")
                    .accessibilityAddTraits(.updatesFrequently)
            }.padding().frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Chirp").controlSize(.large)
    }
    @ViewBuilder var resultActions: some View {
        Button("Copy", systemImage: "doc.on.doc") { model.copy() }.buttonStyle(.bordered).keyboardShortcut("c", modifiers: [.command, .shift])
        ShareLink(item: model.text) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
        if model.canUseRaw { Button("Use raw") { model.useRaw() }.accessibilityIdentifier("chirp.dictation.raw").buttonStyle(.bordered).keyboardShortcut("z", modifiers: [.command, .shift]) }
    }
    var status: String {
        switch model.phase {
        case .idle: "Microphone off"
        case .armed: "Session armed · microphone active"
        case .connecting: "Connecting…"
        case .listening: "Listening…"
        case .correcting: "Polishing…"
        case .finished: "Finished · microphone still active"
        case .failed: "Session unavailable"
        }
    }
}

struct PairingView: View {
    @ObservedObject var model: SessionCoordinator
    @State private var link = ""
    @State private var scanner = false
    @FocusState private var linkFocused: Bool
    var body: some View {
        Form {
            Section("Connect your Mac") {
                Text("Connect Tailscale on both devices. On your Mac, run chirp-server pair and scan its secret QR here. Chirp verifies the connection before saving your pairing.")
                Button("Scan pairing QR", systemImage: "qrcode.viewfinder") { scanner = true }
                    .disabled(model.armed || model.working).frame(minHeight: 44)
                SecureField("Secret pairing link", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("pairingLink").focused($linkFocused)
                PasteButton(payloadType: String.self) { values in link = String((values.first ?? "").prefix(16_384)) }
                Button("Test connection and save pairing") {
                    let secret = link; link = ""; linkFocused = false
                    Task { await model.pair(link: secret) }
                }.disabled(link.isEmpty || model.working || model.armed).frame(minHeight: 44)
            }
            if model.paired {
                Section("Saved pairing") {
                    Label("Mac pairing saved", systemImage: "checkmark.shield")
                    LabeledContent("Mac", value: model.pairedHost)
                    if let engine = model.health?.engine { LabeledContent("Engine", value: String(engine.prefix(128))) }
                    Button("Check Mac connection") { Task { await model.checkConnection() } }.frame(minHeight: 44)
                    Button("Forget pairing", role: .destructive) { model.forgetPairing() }.frame(minHeight: 44)
                }
            }
            Section { Text(model.notice).accessibilityAddTraits(.updatesFrequently) }
        }.navigationTitle("Pair Mac")
            .sheet(isPresented: $scanner) {
                NavigationStack {
                    PairingScanner { secret in
                        scanner = false
                        Task { await model.pair(link: secret) }
                    }
                    .navigationTitle("Scan secret pairing QR")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanner = false } } }
                }
                .modifier(PrivacyShield())
            }
            .onDisappear { link = "" }
    }
}
