import ChirpIOSCore
import SwiftUI
import UIKit

/// Pair with the Mac: scan its QR first, or paste the secret link. A successful scan or paste verifies the
/// connection and saves at once; there is no separate save step. Used by onboarding (page 2) and
/// Settings → Connection.
///
/// The secret link never shows: it sits in a `SecureField`, is capped at 16 KiB, and is cleared on submit
/// and when the form disappears. Pairing is disabled while a session is armed.
struct PairingForm: View {
    @ObservedObject var model: SessionCoordinator
    /// Onboarding hides the scan and paste controls once connected: its own Continue is the next step.
    var hidesControlsWhenConnected = false
    /// Called after the Mac verified and the pairing saved.
    var paired: () -> Void = {}
    @State private var link = ""
    @State private var scanner = false
    @State private var pasting = false
    @State private var outcome: Outcome?
    @FocusState private var linkFocused: Bool

    enum Outcome: Equatable { case connected, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s16) {
            state
            if !(hidesControlsWhenConnected && outcome == .connected && model.paired) { controls }
        }
        .sheet(isPresented: $scanner) {
            NavigationStack {
                PairingScanner { secret in
                    scanner = false
                    connect(secret)
                }
                .navigationTitle("Scan pairing code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanner = false } } }
            }
            .modifier(PrivacyShield())
        }
        .onDisappear { link = "" }
    }

    @ViewBuilder private var controls: some View {
        Button { scanner = true } label: { Label(outcome == nil ? "Scan code" : "Scan again", systemImage: "qrcode.viewfinder") }
            .buttonStyle(.pondPrimary).disabled(model.armed || model.working)
            .accessibilityIdentifier("chirp.pair.scan")
        if pasting {
            VStack(alignment: .leading, spacing: ChirpSpacing.s8) {
                SecureField("Secret pairing link", text: $link)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($linkFocused).submitLabel(.go).onSubmit(submit)
                    .padding(.horizontal, ChirpSpacing.s12).frame(minHeight: 44)
                    .background(Color.chirp.surfaceRaised, in: RoundedRectangle(cornerRadius: ChirpRadius.row, style: .continuous))
                    .accessibilityIdentifier("pairingLink")
                HStack(spacing: ChirpSpacing.s8) {
                    PasteButton(payloadType: String.self) { values in
                        link = String((values.first ?? "").prefix(16_384))
                        submit()
                    }
                    .labelStyle(.titleAndIcon).buttonBorderShape(.capsule).tint(Color.chirp.koi)
                    Button("Connect", action: submit).buttonStyle(.pondTonal)
                        .disabled(link.isEmpty || model.working || model.armed)
                        .accessibilityIdentifier("chirp.pair.submit")
                }
                Text("Pasting a link connects right away.").font(.footnote).foregroundStyle(Color.chirp.inkMuted)
            }
        } else {
            Button("Paste link instead") { pasting = true; linkFocused = true }
                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                .disabled(model.armed).accessibilityIdentifier("chirp.pair.paste")
        }
        if model.armed {
            Text("End the session to change pairing.").font(.footnote).foregroundStyle(Color.chirp.inkMuted)
        }
    }

    @ViewBuilder private var state: some View {
        if model.working {
            HStack(spacing: ChirpSpacing.s12) {
                ProgressView()
                Text("Connecting to your Mac…").font(.subheadline.weight(.semibold))
            }
            .frame(minHeight: 44).accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("chirp.pair.checking")
        } else if case .failed(let cause)? = outcome {
            PondBanner(kind: .error, title: "Couldn’t pair with your Mac", detail: cause, action: "Retry", actionID: "chirp.pair.retry") {
                scanner = !pasting
                linkFocused = pasting
            }
        } else if outcome == .connected, model.paired {
            PondBanner(kind: .success, title: "Connected to \(model.pairedHost)",
                       detail: model.health?.engine.map { "Engine: \(String($0.prefix(128)))" })
                .accessibilityIdentifier("chirp.pair.connected")
        }
    }

    private func submit() {
        guard !link.isEmpty, !model.working, !model.armed else { return }
        let secret = link; link = ""; linkFocused = false
        connect(secret)
    }

    private func connect(_ secret: String) {
        outcome = nil
        Task {
            if await model.pair(link: secret) {
                outcome = .connected; pasting = false
                paired()
            } else {
                outcome = .failed(model.connectionIssue?.message ?? "Check the code, Tailscale on both devices, and that Chirp is running on your Mac.")
            }
        }
    }
}

/// Settings → Connection: the saved pairing and how to change it.
struct PairingView: View {
    @ObservedObject var model: SessionCoordinator
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ChirpSpacing.s24) {
                if model.paired { saved }
                card {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.paired ? "Change pairing" : "Pair your Mac").font(.headline)
                        Spacer()
                        LearnMore(title: "Pairing") { pairingHelp }
                    }
                    Text("On your Mac, open Chirp → Settings → Devices → Pair a Phone.")
                        .font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                    PairingForm(model: model)
                }
                if !model.notice.isEmpty {
                    Text(model.notice).font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(ChirpSpacing.gutter(sizeClass))
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .background(Color.chirp.background)
        .navigationTitle("Connection")
    }

    private var saved: some View {
        card {
            Label("Mac pairing saved", systemImage: "checkmark.shield.fill").font(.headline)
                .foregroundStyle(Color.chirp.lily).symbolRenderingMode(.hierarchical)
            row("Mac", model.pairedHost)
            if let device = model.pairedDevice {
                row("This device", device).accessibilityIdentifier("chirp.pair.device")
            } else {
                Text("Paired with your Mac's shared token. For a pairing you can revoke on its own, run chirp-server pair --name \"\(UIDevice.current.model)\" on your Mac and pair again.")
                    .font(.footnote).foregroundStyle(Color.chirp.inkMuted)
            }
            if let engine = model.health?.engine { row("Engine", String(engine.prefix(128))) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ChirpSpacing.s8) { checkButton; forgetButton }
                VStack(alignment: .leading, spacing: ChirpSpacing.s8) { checkButton; forgetButton }
            }
        }
    }

    private var checkButton: some View {
        Button("Check Mac connection") { Task { await model.checkConnection() } }.buttonStyle(.capsuleChip).disabled(model.working)
    }

    private var forgetButton: some View {
        Button("Forget pairing", role: .destructive) { model.forgetPairing() }
            .font(.subheadline.weight(.medium)).foregroundStyle(Color.chirp.record).frame(minHeight: 44).padding(.horizontal, ChirpSpacing.s16)
            .background(Color.chirp.surfaceRaised, in: Capsule())
    }

    private func row(_ title: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { Text(title).foregroundStyle(Color.chirp.inkMuted); Spacer(); Text(value).multilineTextAlignment(.trailing) }
            VStack(alignment: .leading, spacing: 2) { Text(title).foregroundStyle(Color.chirp.inkMuted); Text(value) }
        }
        .font(.subheadline).accessibilityElement(children: .combine)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s12, content: content)
            .padding(ChirpSpacing.s16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.chirp.surface, in: RoundedRectangle(cornerRadius: ChirpRadius.panel, style: .continuous))
    }

    @ViewBuilder private var pairingHelp: some View {
        Text("Connect Tailscale on both devices. On your Mac, open Chirp → Settings → Devices → Pair a Phone… (or run chirp-server pair --name \"\(UIDevice.current.model)\") and scan its secret QR here.")
        Text("Chirp verifies the connection before it saves the pairing. The pairing is stored in this device's Keychain; the link is never shown or logged.")
    }
}
