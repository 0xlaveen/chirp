import ChirpIOSCore
import SwiftUI

@main
struct ChirpApp: App {
    // Not observed here: the views and commands observe it. Observing it in the App re-ran this body on
    // every published change, and SwiftUI may evaluate the new window closure on its async render thread
    // (seen while rotating during dictation), where the main-actor closure trapped.
    private let coordinator: SessionCoordinator
    init() {
        PrivacyController.shared.start()
        #if DEBUG
        coordinator = ProcessInfo.processInfo.arguments.contains("--chirp-ui-test") ? SessionCoordinator.synthetic(sharedKeyboard: KeyboardTestMode.enabled) : .shared
        #else
        coordinator = .shared
        #endif
    }
    var body: some Scene {
        WindowGroup { ChirpScene(coordinator: coordinator) }
            .commands { DictationCommands(model: coordinator) }
    }
}

struct ChirpScene: View {
    let coordinator: SessionCoordinator
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
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
    private var root: some View {
        ChirpRootView(model: coordinator)
            .onChange(of: scenePhase) { _, phase in if phase == .active { coordinator.refreshSetup(); coordinator.reconcile() } }
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

/// Hardware-keyboard shortcuts. As app commands they work from every tab and are listed in the iPad's
/// hold-⌘ overlay and menu bar. ⌘Space is Spotlight on iPadOS, so dictation uses ⌘Return.
struct DictationCommands: Commands {
    @ObservedObject var model: SessionCoordinator
    private var active: Bool { [.connecting, .listening, .correcting].contains(model.phase) }
    var body: some Commands {
        CommandMenu("Dictation") {
            if active {
                Button("Stop Dictation") { model.stopDictation() }
                    .keyboardShortcut(.return, modifiers: .command).disabled(model.phase == .correcting)
            } else {
                Button("Start Dictation") { Task { do { try await model.begin() } catch { model.show(error) } } }
                    .keyboardShortcut(.return, modifiers: .command).disabled(!model.paired || model.working)
            }
            Button("Cancel Dictation") { model.cancelDictation() }
                .keyboardShortcut(".", modifiers: .command).disabled(!active)
            Divider()
            Button("Copy Result") { model.copy() }
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(model.phase != .finished)
            Button("Use Raw Transcript") { model.useRaw() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canUseRaw)
            Divider()
            Button("Start Keyboard Session") { Task { do { try await model.armSession() } catch { model.show(error) } } }
                .keyboardShortcut("k", modifiers: [.command, .shift]).disabled(model.armed || !model.paired || model.working)
            Button("End Session") { model.endSession() }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!model.armed)
        }
    }
}

enum ChirpTab: Hashable { case dictate, pair, styles, history, settings }

struct ChirpRootView: View {
    @ObservedObject var model: SessionCoordinator
    @State private var tab = ChirpTab.dictate
    var body: some View {
        // The session bar goes inside each tab: inset on the TabView itself, it covered iOS 27's floating
        // tab bar, so tapping a tab while armed hit End session instead.
        TabView(selection: $tab) {
            NavigationStack { DictationView(model: model, tab: $tab) }.modifier(SessionBar(model: model))
                .tabItem { Label("Dictate", systemImage: "mic") }.tag(ChirpTab.dictate)
            NavigationStack { PairingView(model: model) }.modifier(SessionBar(model: model))
                .tabItem { Label("Pair Mac", systemImage: "qrcode.viewfinder") }.tag(ChirpTab.pair)
            NavigationStack { StylesView(model: model) }.modifier(SessionBar(model: model))
                .tabItem { Label("Styles", systemImage: "sparkles") }.tag(ChirpTab.styles)
            NavigationStack { HistoryView(model: model) }.modifier(SessionBar(model: model))
                .tabItem { Label("History", systemImage: "clock") }.tag(ChirpTab.history)
            NavigationStack { SessionSettingsView(model: model) }.modifier(SessionBar(model: model))
                .tabItem { Label("Settings", systemImage: "gear") }.tag(ChirpTab.settings)
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

struct SessionBar: ViewModifier {
    @ObservedObject var model: SessionCoordinator
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if model.armed {
                VStack(spacing: 8) {
                    Label("Microphone active throughout session", systemImage: "mic.fill").font(.footnote)
                    Button("End session", role: .destructive) { model.endSession() }
                        .accessibilityIdentifier("chirp.session.end")
                        .buttonStyle(.bordered).frame(minHeight: 44)
                }
                .frame(maxWidth: .infinity).padding(8).background(.regularMaterial)
            }
        }
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
    @Binding var tab: ChirpTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var guide = false
    var active: Bool { [.connecting, .listening, .correcting].contains(model.phase) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(status, systemImage: model.armed ? "mic.fill" : "mic.slash")
                    .font(.title2.bold()).accessibilityIdentifier("sessionStatus")
                Text(model.armed ? "Idle audio is discarded immediately. Audio is sent to your paired Mac only while dictating. Switch back to your other app and choose Chirp Keyboard to dictate there." : "Start a session here, then dictate in any app with Chirp Keyboard. The microphone stays active until the session ends.")
                    .foregroundStyle(.secondary)
                if let issue = model.connectionIssue, issue.isOffline {
                    HStack {
                        Label("Mac offline", systemImage: "wifi.slash").font(.headline).foregroundStyle(.orange)
                        Spacer()
                        Button("Check again") { Task { await model.checkConnection() } }
                            .buttonStyle(.bordered).disabled(model.working).accessibilityIdentifier("chirp.offline.retry")
                    }.accessibilityIdentifier("chirp.offline")
                }
                if !model.armed {
                    Button("Start keyboard session") { Task { do { try await model.armSession() } catch { model.show(error) } } }
                        .buttonStyle(.bordered).disabled(!model.paired || model.working).frame(minHeight: 44)
                }
                if active {
                    Button("Stop dictation", systemImage: "stop.fill") { model.stopDictation() }
                        .accessibilityIdentifier("chirp.dictation.stop")
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                    Button("Cancel dictation", role: .cancel) { model.cancelDictation() }
                        .buttonStyle(.bordered).keyboardShortcut(.escape, modifiers: []).frame(minHeight: 44)
                } else {
                    Button("Dictate", systemImage: "mic.fill") { Task { do { try await model.begin() } catch { model.show(error) } } }
                        .accessibilityIdentifier("chirp.dictation.start")
                        .buttonStyle(.borderedProminent)
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
                Divider()
                SetupChecklist(model: model, tab: $tab)
                DisclosureGroup("How to dictate in other apps", isExpanded: $guide) { OtherAppsGuide() }
                    .accessibilityIdentifier("chirp.guide")
            }.padding().frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Chirp").controlSize(.large)
            .onAppear { if !model.paired || !model.keyboardReady { guide = true } }
    }
    @ViewBuilder var resultActions: some View {
        Button("Copy", systemImage: "doc.on.doc") { model.copy() }.buttonStyle(.bordered)
        ShareLink(item: model.text) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
        if model.canUseRaw { Button("Use raw") { model.useRaw() }.accessibilityIdentifier("chirp.dictation.raw").buttonStyle(.bordered) }
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

/// The three things that must be true before Chirp Keyboard can dictate in another app.
struct SetupChecklist: View {
    @ObservedObject var model: SessionCoordinator
    @Binding var tab: ChirpTab
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Chirp Keyboard").font(.headline)
            step(1, done: model.paired, title: "Pair your Mac",
                 detail: model.paired ? "Paired with \(model.pairedHost)." : "Run chirp-server pair on your Mac and scan its QR.") {
                if !model.paired { Button("Pair Mac") { tab = .pair }.buttonStyle(.bordered) }
            }
            step(2, done: model.keyboardReady, title: "Turn on Chirp Keyboard",
                 detail: model.keyboardReady
                     ? "Chirp Keyboard is on with Full Access."
                     : "In Settings, tap Keyboards, then turn on Chirp Keyboard and Allow Full Access. Open Chirp Keyboard once in any app and this step shows as done.") {
                if !model.keyboardReady {
                    Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                        Label("Open Chirp in Settings", systemImage: "gear")
                    }.buttonStyle(.bordered).accessibilityIdentifier("chirp.setup.settings")
                }
            }
            step(3, done: model.armed, title: "Start a keyboard session",
                 detail: model.armed ? "Session running. Chirp Keyboard can dictate now." : "Tap Start keyboard session above. Chirp Keyboard only dictates while a session runs.") {}
        }.accessibilityIdentifier("chirp.setup")
    }
    private func step<Action: View>(_ number: Int, done: Bool, title: String, detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2).foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityLabel(done ? "Done" : "Step \(number)")
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                action()
            }
        }.accessibilityElement(children: .contain)
    }
}

struct OtherAppsGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("On screen: tap a text field in any app, touch and hold the globe key and choose Chirp. Tap Start dictation, then Stop dictation. The text appears where you were typing. Tap the globe key to go back to your usual keyboard.",
                  systemImage: "hand.tap")
            Label("With a hardware keyboard: iPadOS hides on-screen keyboards. Press the globe key (or Control-Space) until Chirp is chosen, then use the small keyboard bar at the bottom of the screen to show it.",
                  systemImage: "keyboard")
            Label("From any app with a hardware keyboard: start a session here, then press ⌘Space, type Toggle dictation and press Return. Do it again to stop. The text is copied, so press ⌘V to paste.",
                  systemImage: "magnifyingglass")
            Label("One key for it: in the Shortcuts app, make a shortcut with Chirp's Toggle Chirp dictation action. Then go to Settings → Accessibility → Keyboards & Typing → Full Keyboard Access, turn it on, open Commands and give that shortcut a key combination.",
                  systemImage: "command")
            Label("Inside Chirp: ⌘Return starts or stops dictation, ⌘. cancels, ⌘⇧K starts a keyboard session and ⌘⇧E ends it. Hold ⌘ to see every shortcut.",
                  systemImage: "keyboard.badge.ellipsis")
        }.font(.subheadline).padding(.top, 8)
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
