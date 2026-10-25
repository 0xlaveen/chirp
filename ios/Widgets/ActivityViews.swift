import SwiftUI

/// Shared Pond pieces for the Live Activities and the Dynamic Island. Colours are the `ChirpIOSCore/Pond.swift` tokens
/// (compiled into this target); activities can't run the animated Ripple, so listening shows its static koi ring.

/// The brand mark for an activity: a koi ring around a waveform. The ring is `koiDecor` (large shape only), the waveform
/// is `koi`; a stale status is the moon, an error or the DEBUG notice is `record`.
struct ActivityGlyph: View {
    enum Tone { case koi, moon, record }
    var tone: Tone = .koi
    /// Listening: a second, fainter ring, the still frame of the Ripple.
    var listening = false
    var size: CGFloat = 36

    private var ink: Color {
        switch tone {
        case .koi: Color.chirp.koi
        case .moon: Color.chirp.moon
        case .record: Color.chirp.record
        }
    }
    private var ring: Color {
        switch tone {
        case .koi: Color.chirp.koiDecor
        case .moon: Color.chirp.moonFill
        case .record: Color.chirp.record
        }
    }

    var body: some View {
        ZStack {
            if listening {
                Circle().strokeBorder(ring.opacity(0.28), lineWidth: max(size / 16, 1)).frame(width: size, height: size)
            }
            Circle().strokeBorder(ring, lineWidth: max(size / 14, 1.5)).frame(width: size * (listening ? 0.74 : 0.92), height: size * (listening ? 0.74 : 0.92))
            Image(systemName: tone == .moon ? "moon.stars.fill" : "waveform")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(ink)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A capsule action for a `Button(intent:)`: a filled `record` capsule (Stop, End session), a koi one (Start) or a quiet
/// raised one (Cancel, Pause).
struct ActivityCapsule: View {
    enum Style { case koi, record, quiet, recordOutline }
    var title: String
    var symbol: String
    var style: Style

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .foregroundStyle(ink)
            .background(Capsule().fill(fill))
            .overlay { if style == .recordOutline { Capsule().strokeBorder(Color.chirp.record, lineWidth: 1.5) } }
            .contentShape(Capsule())
    }

    private var fill: Color {
        switch style {
        case .koi: Color.chirp.koi
        case .record: Color.chirp.record
        case .quiet: Color.chirp.surfaceRaised
        case .recordOutline: .clear
        }
    }
    private var ink: Color {
        switch style {
        case .koi: Color.chirp.onKoi
        case .record: Color(red: 1, green: 1, blue: 1)
        case .quiet: Color.chirp.ink
        case .recordOutline: Color.chirp.record
        }
    }
}

/// The "● Recording" style line: a `record` dot and a label.
struct RecordDot: View {
    var body: some View {
        Circle().fill(Color.chirp.record).frame(width: 9, height: 9).accessibilityHidden(true)
    }
}

/// The DEBUG-retention banner: always shown while the server keeps recordings.
struct DebugBanner: View {
    var body: some View {
        Label("DEBUG recordings kept", systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.chirp.record)
    }
}

extension View {
    /// The lock-screen card: Pond `background` (`#0D1526` in dark, the light Pond surface in light).
    func pondActivityCard() -> some View {
        padding(16)
            .activityBackgroundTint(Color.chirp.background)
            .activitySystemActionForegroundColor(Color.chirp.koi)
    }
}
