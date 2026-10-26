import ChirpCore
import ChirpIOSCore
import GameController
import SwiftUI

/// Dictate: a calm page with one big control, modelled on Android's Scratchpad. A short status line and
/// timer on top, at most one connection banner, the transcript as a page, and the mic at the bottom centre.
/// Help (other apps, the keyboard session) sits behind ⓘ.
struct DictateView: View {
    @ObservedObject var model: SessionCoordinator
    @ObservedObject private var shortcuts = HardwareShortcutController.shared
    /// Opens Settings → Connection (refused pairing, not paired).
    var openConnection: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var listeningSince: Date?
    @State private var hardwareKeyboard = DictateView.keyboardAttached

    var active: Bool { [.connecting, .listening, .correcting].contains(model.phase) }

    /// A phone on its side has about 200 pt of height under the navigation bar: the mic would cover the page
    /// (and Use raw with it), so the controls sit in a column beside it instead.
    private var controlsBeside: Bool { verticalSizeClass == .compact && !typeSize.isAccessibilitySize }

    var body: some View {
        Group {
            if controlsBeside {
                HStack(spacing: 0) {
                    pageScroll
                    ScrollView {
                        controls.padding(.horizontal, ChirpSpacing.s16).padding(.vertical, ChirpSpacing.s8)
                    }
                    .scrollBounceBehavior(.basedOnSize).frame(width: 220)
                }
            } else {
                pageScroll.safeAreaInset(edge: .bottom, spacing: 0) {
                    if !typeSize.isAccessibilitySize {
                        controls.padding(.horizontal, ChirpSpacing.gutter(sizeClass)).padding(.top, ChirpSpacing.s12).padding(.bottom, ChirpSpacing.s16)
                            .frame(maxWidth: .infinity).background(Color.chirp.background)
                    }
                }
            }
        }
        .background(Color.chirp.background)
        .navigationTitle("Dictate").navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.phase, initial: true) { _, phase in
            if phase == .listening { if listeningSince == nil { listeningSince = .now } }
            else if phase != .connecting { listeningSince = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in hardwareKeyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in hardwareKeyboard = Self.keyboardAttached }
    }

    private var pageScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ChirpSpacing.s16) {
                statusLine
                banner
                page
                // At accessibility text sizes the controls scroll with the page instead of covering it.
                if typeSize.isAccessibilitySize { controls }
                if model.phase == .finished { results }
                if !model.notice.isEmpty {
                    Text(model.notice).font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                        .accessibilityIdentifier("sessionNotice").accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(.horizontal, ChirpSpacing.gutter(sizeClass)).padding(.top, ChirpSpacing.s8).padding(.bottom, ChirpSpacing.s24)
            .frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Top

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: ChirpSpacing.s8) {
            Text(status).font(.title3.weight(.semibold)).foregroundStyle(statusColor)
                .accessibilityIdentifier("sessionStatus").accessibilityAddTraits(.updatesFrequently)
            if let listeningSince, active {
                TimelineView(.periodic(from: listeningSince, by: 1)) { context in
                    Text(Self.clock(context.date.timeIntervalSince(listeningSince)))
                        .font(ChirpType.timer(.title3)).foregroundStyle(Color.chirp.inkMuted)
                }
                .accessibilityLabel("Elapsed")
            }
            Spacer(minLength: 0)
        }
    }

    var status: String {
        switch model.phase {
        case .idle: "Microphone off"
        case .armed: "Ready"
        case .connecting: "Connecting…"
        case .listening: "Listening…"
        case .correcting: "Polishing…"
        case .finished: "Finished"
        case .failed: "Session unavailable"
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .listening: Color.chirp.record
        case .correcting: Color.chirp.moon
        default: Color.chirp.ink
        }
    }

    /// The one banner slot: the most important connection problem, with its one fix.
    @ViewBuilder private var banner: some View {
        if !model.paired {
            PondBanner(kind: .info, title: "Pair your computer to dictate", action: "Pair", actionID: "chirp.pair.open", perform: openConnection)
        } else if model.connectionIssue == .refused {
            PondBanner(kind: .error, title: "Computer refused this device", action: "Pair again", actionID: "chirp.refused.pair", perform: openConnection)
                .accessibilityIdentifier("chirp.refused")
        } else if let issue = model.connectionIssue, issue.isOffline || issue == .loading {
            PondBanner(kind: .warning, title: issue == .loading ? "Computer loading its model" : "Computer offline",
                       action: "Check again", actionID: "chirp.offline.retry") { Task { await model.checkConnection() } }
                .disabled(model.working).accessibilityIdentifier("chirp.offline")
        }
    }

    // MARK: The page

    /// Long dictation shows the segments that already landed before the live one.
    var shownText: String { LongText.join([model.earlierText, model.text].filter { !$0.isEmpty }) }

    @ViewBuilder private var page: some View {
        if shownText.isEmpty {
            VStack(spacing: ChirpSpacing.s12) {
                ChirpBrand.glyph.resizable().scaledToFit().frame(width: 56, height: 56)
                    .foregroundStyle(Color.chirp.koi.opacity(0.35)).accessibilityHidden(true)
                Text(active ? "Speak now" : "Tap the mic to dictate").font(.body).foregroundStyle(Color.chirp.inkMuted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, typeSize.isAccessibilitySize ? ChirpSpacing.s8 : ChirpSpacing.s48)
        } else {
            Text(shownText).font(.title3).foregroundStyle(Color.chirp.ink).lineSpacing(4)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(ChirpSpacing.s16)
                .background(Color.chirp.surface, in: RoundedRectangle(cornerRadius: ChirpRadius.panel, style: .continuous))
                .accessibilityIdentifier("transcript")
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.phase)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ChirpSpacing.s8) {
                    Button("Copy", systemImage: "doc.on.doc") { model.copy() }.buttonStyle(.capsuleChip)
                        .accessibilityIdentifier("chirp.dictation.copy")
                    ShareLink(item: shownText) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(.capsuleChip)
                    if model.canUseRaw { useRaw }
                    // "Save as note" joins these once the Notes library (#193) can take a note from here.
                }
            }
            .scrollClipDisabled()
            if !model.raw.isEmpty, model.raw != model.text {
                DisclosureGroup {
                    Text(model.raw).font(.body).foregroundStyle(Color.chirp.inkMuted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, ChirpSpacing.s8)
                } label: {
                    Text("Before clean-up").font(.subheadline.weight(.semibold)).foregroundStyle(Color.chirp.moon)
                }
                .tint(Color.chirp.moon)
                .padding(.leading, ChirpSpacing.s12)
                .overlay(alignment: .leading) { Capsule().fill(Color.chirp.moonFill).frame(width: 3) }
                .accessibilityIdentifier("chirp.dictation.beforeCleanup")
            }
        }
    }

    /// Use raw, with the seconds it stays on offer (like the keyboard's "Use raw (4s)").
    private var useRaw: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = model.rawExpiresAt.map { max(0, Int($0.timeIntervalSince(context.date).rounded(.up))) }
            Button(left.map { "Use raw (\($0)s)" } ?? "Use raw", systemImage: "arrow.uturn.backward") { model.useRaw() }
                .buttonStyle(.capsuleChip)
                .accessibilityLabel("Use raw")
                .accessibilityIdentifier("chirp.dictation.raw")
        }
    }

    // MARK: The mic

    private var controls: some View {
        VStack(spacing: ChirpSpacing.s12) {
            MicButton(model: model, reduceMotion: reduceMotion || Self.forcedReduceMotion)
            if active {
                Button("Cancel", role: .cancel) { model.cancelDictation() }
                    .font(.body.weight(.medium)).foregroundStyle(Color.chirp.inkMuted).frame(minWidth: 88, minHeight: 44)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel("Cancel dictation").accessibilityIdentifier("chirp.dictation.cancel")
            } else if !model.armed {
                VStack(spacing: ChirpSpacing.s4) {
                    HStack(spacing: ChirpSpacing.s4) {
                        Button("Start keyboard session") { Task { do { try await model.armSession() } catch { model.show(error) } } }
                            .buttonStyle(.pondTonal).disabled(!model.paired || model.working)
                            .accessibilityIdentifier("chirp.session.start")
                        LearnMore(title: "Keyboard session") {
                            Text("A keyboard session keeps the microphone ready so Chirp Keyboard can dictate in other apps. Idle audio is discarded immediately; audio goes to your paired computer only while you dictate.")
                            Text("The session ends by itself after the length set in Settings, or when you tap End.")
                            OtherAppsGuide()
                        }
                    }
                    Text("Lets Chirp Keyboard dictate in other apps").font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                        .multilineTextAlignment(.center)
                }
            }
            if hardwareKeyboard, sizeClass == .regular {
                Text(shortcuts.shortcut.enabled ? "\(shortcuts.shortcut.mode == .hold ? "Hold" : "Press") \(shortcuts.shortcut.title) or ⌘Return to dictate · Esc to cancel"
                     : "⌘Return to dictate · ⌘. to cancel").font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                    .accessibilityIdentifier("chirp.dictation.shortcutsHint")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// `--chirp-reduce-motion` (Debug) draws the Ripple as Reduce Motion would, for the Reduce Motion snapshots.
    static var forcedReduceMotion: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--chirp-reduce-motion")
        #else
        false
        #endif
    }

    /// A hardware keyboard is attached (snapshots can force the hint on with `--chirp-hardware-keyboard`).
    static var keyboardAttached: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--chirp-hardware-keyboard") { return true }
        #endif
        return GCKeyboard.coalesced != nil
    }

    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The one big control: koi mic to start, `record` Stop with the Ripple while listening, a moon disc while
/// polishing. 88 pt, with the Ripple's rings drawn outside it.
struct MicButton: View {
    @ObservedObject var model: SessionCoordinator
    var reduceMotion: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var side: CGFloat = 88

    var body: some View {
        let size = min(max(side, 88), 132)
        ZStack {
            if model.phase == .listening {
                if reduceMotion {
                    // Reduce Motion: one steady ring with a gap around the Stop disc, so it reads as a ring.
                    Circle().strokeBorder(Color.chirp.record.opacity(0.55), lineWidth: 4)
                        .frame(width: size * 1.36, height: size * 1.36)
                        .accessibilityHidden(true)
                } else {
                    Ripple(level: 0.35).frame(width: size * 1.8, height: size * 1.8)
                }
            }
            switch model.phase {
            case .listening, .connecting:
                Button { model.stopDictation() } label: {
                    disc(fill: model.phase == .listening ? Color.chirp.record : Color.chirp.koi, size: size) {
                        if model.phase == .connecting { ProgressView().tint(Color.chirp.onKoi) }
                        else { Image(systemName: "stop.fill").font(.system(size: size * 0.32, weight: .bold)) }
                    }
                }
                .accessibilityLabel("Stop dictation").accessibilityIdentifier("chirp.dictation.stop")
            case .correcting:
                disc(fill: Color.chirp.moonFill, size: size, ink: Color(red: 0x40 / 255, green: 0x2D / 255, blue: 0)) {
                    Image(systemName: "sparkles").font(.system(size: size * 0.34, weight: .semibold))
                        .symbolEffect(.pulse, isActive: !reduceMotion)
                }
                .accessibilityElement().accessibilityLabel("Polishing").accessibilityIdentifier("chirp.dictation.polishing")
            default:
                Button { Task { do { try await model.begin() } catch { model.show(error) } } } label: {
                    disc(fill: Color.chirp.koi, size: size) {
                        Image(systemName: "mic.fill").font(.system(size: size * 0.36, weight: .semibold))
                    }
                }
                .disabled(!model.paired || model.working)
                .opacity(!model.paired || model.working ? 0.45 : 1)
                .accessibilityLabel("Dictate").accessibilityIdentifier("chirp.dictation.start")
            }
        }
        .frame(width: size * 1.8, height: size * 1.8)
        .buttonStyle(MicPressStyle())
    }

    private func disc<Icon: View>(fill: Color, size: CGFloat, ink: Color = Color.chirp.onKoi,
                                  @ViewBuilder icon: () -> Icon) -> some View {
        Circle().fill(fill).frame(width: size, height: size)
            .overlay { icon().foregroundStyle(ink) }
            .shadow(color: fill.opacity(0.35), radius: 12, y: 4)
            .contentShape(Circle())
    }
}

private struct MicPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.95 : 1).animation(.smooth(duration: 0.12), value: configuration.isPressed)
    }
}
