import AVFAudio
import ChirpIOSCore
import SwiftUI
import UIKit

/// First-run setup (a port of Android's four-page wizard): Welcome · Pair your Mac · Microphone · Chirp
/// Keyboard. Segmented progress on top, one koi primary button per page and a quiet "Skip for now". It shows
/// on first launch until the device is paired, and again from Settings → "Show setup again".
struct Onboarding: View {
    enum Page: Int, CaseIterable { case welcome, pair, microphone, keyboard }
    /// Set once onboarding is finished or skipped. Unpaired first launches show it until then.
    static let doneKey = "chirp.onboarding.done"

    @ObservedObject var model: SessionCoordinator
    /// Ends onboarding; the app lands on Notes.
    var finish: () -> Void
    @State private var page = Page.welcome
    @State private var microphone = AVAudioApplication.shared.recordPermission
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if page == .welcome { hero(height: typeSize.isAccessibilitySize ? 160 : min(max(proxy.size.height * 0.42, 220), 420)) }
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, ChirpSpacing.gutter(sizeClass) + ChirpSpacing.s8)
                        .padding(.top, page == .welcome ? ChirpSpacing.s24 : ChirpSpacing.s32)
                        .frame(maxWidth: 560).frame(maxWidth: .infinity)
                    // At accessibility text sizes the buttons scroll with the page instead of covering it.
                    if typeSize.isAccessibilitySize { actions.padding(.top, ChirpSpacing.s24) }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .top, spacing: 0) { progress }
            .safeAreaInset(edge: .bottom, spacing: 0) { if !typeSize.isAccessibilitySize { actions } }
        }
        .background(Color.chirp.background.ignoresSafeArea())
        .animation(reduceMotion ? nil : .smooth, value: page)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { microphone = AVAudioApplication.shared.recordPermission; model.refreshSetup() }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("chirp.onboarding")
    }

    // MARK: Chrome

    /// Four segments; the current page and the ones before it fill koi.
    private var progress: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.self) { item in
                    Capsule().fill(item.rawValue <= page.rawValue ? Color.chirp.koi : Color.chirp.surfaceRaised).frame(height: 4)
                }
            }
            .padding(.vertical, ChirpSpacing.s12)
            .accessibilityElement().accessibilityLabel("Step \(page.rawValue + 1) of \(Page.allCases.count)")
            if page != .welcome {
                Button { go(Page(rawValue: page.rawValue - 1)!) } label: {
                    Label("Back", systemImage: "chevron.backward").font(.body.weight(.medium))
                }
                .frame(minHeight: 44).accessibilityIdentifier("chirp.onboarding.back")
            }
        }
        .padding(.horizontal, ChirpSpacing.gutter(sizeClass))
        .frame(maxWidth: 560).frame(maxWidth: .infinity)
        .background(page == .welcome ? Color.clear : Color.chirp.background)
    }

    private var actions: some View {
        VStack(spacing: ChirpSpacing.s4) {
            primary
            Button(page == .welcome ? "Skip setup" : "Skip for now") {
                if page == .welcome || page == .keyboard { finish() } else { go(Page(rawValue: page.rawValue + 1)!) }
            }
            .font(.body.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("chirp.onboarding.skip")
        }
        .padding(.horizontal, ChirpSpacing.gutter(sizeClass)).padding(.top, ChirpSpacing.s12).padding(.bottom, ChirpSpacing.s8)
        .frame(maxWidth: 560).frame(maxWidth: .infinity)
        .background(Color.chirp.background)
    }

    @ViewBuilder private var primary: some View {
        switch page {
        case .welcome:
            Button("Get started") { go(.pair) }.buttonStyle(.pondPrimary).accessibilityIdentifier("chirp.onboarding.next")
        case .pair:
            // Until paired, the form's Scan code is this page's primary action.
            if model.paired {
                Button("Continue") { go(.microphone) }.buttonStyle(.pondPrimary).accessibilityIdentifier("chirp.onboarding.next")
            }
        case .microphone:
            switch microphone {
            case .granted:
                Button("Continue") { go(.keyboard) }.buttonStyle(.pondPrimary).accessibilityIdentifier("chirp.onboarding.next")
            case .denied:
                Button("Open Settings") { openSettings() }.buttonStyle(.pondPrimary).accessibilityIdentifier("chirp.onboarding.next")
            default:
                Button("Allow microphone") {
                    Task {
                        _ = await AVAudioApplication.requestRecordPermission()
                        microphone = AVAudioApplication.shared.recordPermission
                    }
                }.buttonStyle(.pondPrimary).accessibilityIdentifier("chirp.onboarding.next")
            }
        case .keyboard:
            if model.keyboardReady {
                Button("Open Notes") { finish() }.buttonStyle(.pondPrimary).accessibilityIdentifier("chirp.onboarding.next")
            } else {
                Button("Open Settings") { openSettings() }.buttonStyle(.pondPrimary).accessibilityIdentifier("chirp.onboarding.next")
            }
        }
    }

    // MARK: Pages

    @ViewBuilder private var content: some View {
        switch page {
        case .welcome: welcome
        case .pair: pair
        case .microphone: microphonePage
        case .keyboard: keyboard
        }
    }

    /// The app icon's pond artwork, edge to edge under the progress bar.
    private func hero(height: CGFloat) -> some View {
        Color.chirp.background
            .frame(height: height)
            .overlay { ChirpBrand.pond.resizable().scaledToFill() }
            .clipped()
            .accessibilityHidden(true)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s24) {
            Text("Welcome to Chirp").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: ChirpSpacing.s16) {
                feature("mic", "Dictate into any app")
                feature("note.text", "Keep conversations in Notes")
                feature("lock", "Audio goes only to your own Mac.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func feature(_ symbol: String, _ title: String) -> some View {
        Label {
            Text(title).font(.title3).foregroundStyle(Color.chirp.ink)
        } icon: {
            Image(systemName: symbol).symbolRenderingMode(.hierarchical).foregroundStyle(Color.chirp.koi)
                .frame(width: 32)
        }
    }

    private var pair: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s16) {
            badge(model.paired ? "checkmark" : "qrcode.viewfinder", done: model.paired)
            title("Pair your Mac")
            Text("On your Mac, open Chirp → Settings → Devices → Pair a Phone, then scan the code.")
                .font(.body).foregroundStyle(Color.chirp.inkMuted)
            PairingForm(model: model, hidesControlsWhenConnected: true)
            LearnMore(title: "Pairing", label: "About pairing") {
                Text("Turn on Tailscale on both devices. Chirp checks that your Mac answers before it saves the pairing, so a successful scan is all it takes.")
                Text("Scanning uses the camera only while the scanner is open. The pairing is kept in this device's Keychain and the link is never shown or logged.")
            }
        }
    }

    private var microphonePage: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s16) {
            badge(microphone == .granted ? "checkmark" : "mic", done: microphone == .granted)
            title("Allow the microphone")
            Text("Chirp listens only while you dictate, record a note or keep a keyboard session on.")
                .font(.body).foregroundStyle(Color.chirp.inkMuted)
            if microphone == .granted {
                check("Microphone allowed")
            } else if microphone == .denied {
                PondBanner(kind: .warning, title: "The microphone is off for Chirp", detail: "Turn it on in Settings to dictate.")
            }
        }
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s16) {
            badge(model.keyboardReady ? "checkmark" : "keyboard", done: model.keyboardReady)
            title("Chirp Keyboard")
            Text("Optional. Lets you dictate in other apps.").font(.body).foregroundStyle(Color.chirp.inkMuted)
            if model.keyboardReady {
                check("Chirp Keyboard is on")
            } else {
                Text("In Settings, tap Keyboards and turn on Chirp Keyboard and Allow Full Access.")
                    .font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                LearnMore(title: "Chirp Keyboard", label: "About the keyboard") {
                    Text("Full Access lets the keyboard reach the Chirp app through an encrypted shared mailbox. The keyboard never uses the microphone; Chirp does, while a session runs.")
                    Text("Open Chirp Keyboard once in any app and this step shows as done.")
                    OtherAppsGuide()
                }
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.title.bold()).foregroundStyle(Color.chirp.ink).accessibilityAddTraits(.isHeader)
    }

    private func badge(_ symbol: String, done: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 30, weight: .semibold))
            .foregroundStyle(done ? Color.chirp.lily : scheme == .dark ? Color.chirp.koi : Color.chirp.onKoiContainer)
            .frame(width: 72, height: 72)
            .background(done ? Color.chirp.lily.opacity(0.16) : scheme == .dark ? Color.chirp.surfaceRaised : Color.chirp.koiContainer, in: Circle())
            .accessibilityHidden(true)
    }

    private func check(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill").font(.headline)
            .foregroundStyle(Color.chirp.lily).symbolRenderingMode(.hierarchical)
            .accessibilityIdentifier("chirp.onboarding.done")
    }

    private func go(_ next: Page) { page = next }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
