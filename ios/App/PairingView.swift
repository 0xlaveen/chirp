import ChirpIOSCore
import SwiftUI

/// Pair with your computer: scan its QR first, or paste the secret link. A successful scan or paste verifies the
/// connection and saves at once; there is no separate save step. Used by onboarding and
/// Settings → Connection.
///
/// The secret link never shows: it sits in a `SecureField`, is capped at 16 KiB, and is cleared on submit
/// and when the form disappears. Pairing is disabled while a session is armed.
struct PairingForm: View {
    @ObservedObject var model: SessionCoordinator
    /// Onboarding hides the scan and paste controls once connected: its own Continue is the next step.
    var hidesControlsWhenConnected = false
    /// Called after the computer verified and the pairing saved.
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
                Text("Connecting to your computer…").font(.subheadline.weight(.semibold))
            }
            .frame(minHeight: 44).accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("chirp.pair.checking")
        } else if case .failed(let cause)? = outcome {
            PondBanner(kind: .error, title: "Couldn’t pair with your computer", detail: cause, action: "Retry", actionID: "chirp.pair.retry") {
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
                outcome = .failed(model.connectionIssue?.message ?? "Check the code, Tailscale on both devices, and that Chirp is running on your computer.")
            }
        }
    }
}

