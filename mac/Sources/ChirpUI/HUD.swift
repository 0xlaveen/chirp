import AppKit
import ChirpCore
import Observation
import SwiftUI

/// What the leading symbol of the HUD shows: the live waveform while listening, otherwise the outcome.
public enum HUDIndicator: Equatable, Sendable {
    case waveform, success, clipboard, warning, none

    var symbol: (name: String, label: String)? {
        switch self {
        case .waveform, .none: nil
        case .success: ("checkmark.circle.fill", "Done")
        case .clipboard: ("doc.on.clipboard.fill", "Copied")
        case .warning: ("exclamationmark.triangle.fill", "Problem")
        }
    }
}

/// The HUD's short status wording, in one place so the controller, the snapshots and the tests agree.
public enum HUDStatus {
    public static let connecting = "Connecting…"
    public static let listening = "Listening"
    public static let finishing = "Finishing…"
    public static let inserting = "Inserting…"
    public static let noSpeech = "No speech detected"
}

@MainActor @Observable
public final class HUDModel {
    public var status = ""
    public var stable = ""
    public var unstable = ""
    /// Recent input levels for the waveform, newest last.
    public var levels = LevelHistory()
    public var indicator: HUDIndicator = .waveform
    public var debugRetention = false
    public var isError = false
    public var showUseRaw = false
    /// The inserted text was rewritten by the server's clean-up.
    public var cleaned = false
    /// System display options, read each time the HUD is shown.
    public var reduceMotion = false
    public var increaseContrast = false
    /// Draws an opaque stand-in for the blur: used for Increase Contrast and the offscreen snapshots, which have no
    /// window to blur through. The live panel's translucency is an `NSVisualEffectView` behind this view.
    public var flatSurface = false
    public var onUseRaw: (() -> Void)?

    public init() {}

    public func pushLevel(_ rms: Float) { levels.push(rms: rms) }
    public func silence() { levels.clear() }

    public func reset() {
        status = ""; stable = ""; unstable = ""; levels.clear(); indicator = .waveform
        isError = false; showUseRaw = false; cleaned = false; onUseRaw = nil
    }
}

/// The live level history behind the waveform: the last `capacity` input levels, mapped to 0...1 on a decibel scale
/// (speech sits around -35...-15 dBFS, so a linear RMS would barely move the bars).
public struct LevelHistory: Equatable, Sendable {
    public static let capacity = 16
    public private(set) var samples = [Float](repeating: 0, count: capacity)

    public init() {}

    /// RMS 0...1 to a bar height 0...1: -50 dBFS and below is 0, -14 dBFS and above is 1.
    public static func normalize(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 50) / 36))
    }

    /// Adds a sample. Bars rise at once and fall by a third of the way, so the waveform reads as speech, not as jitter.
    public mutating func push(rms: Float) {
        let target = Self.normalize(rms: rms)
        let last = samples.last ?? 0
        samples.removeFirst()
        samples.append(target >= last ? target : last * 0.65 + target * 0.35)
    }

    public mutating func clear() { samples = [Float](repeating: 0, count: Self.capacity) }

    /// A fixed, speech-like history for the snapshots.
    public static func demo(peak: Float) -> LevelHistory {
        var h = LevelHistory()
        let shape: [Float] = [0.1, 0.25, 0.5, 0.35, 0.7, 0.9, 0.6, 0.4, 0.8, 1, 0.65, 0.45, 0.7, 0.5, 0.3, 0.55]
        h.samples = shape.map { $0 * peak }
        return h
    }
}

public enum HUDViewMetrics {
    /// Corner radius of the HUD: a capsule at one line (the content is 44 pt tall) and a rounded rectangle when it wraps.
    public static let corner: CGFloat = 22
}

public struct HUDView: View {
    static let maxTextWidth: CGFloat = 440

    let model: HUDModel
    let onSize: (CGSize) -> Void

    public init(model: HUDModel, onSize: @escaping (CGSize) -> Void = { _ in }) {
        self.model = model
        self.onSize = onSize
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: HUDViewMetrics.corner, style: .continuous) }

    public var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minWidth: 150, alignment: .leading)
            .background { if model.flatSurface || model.increaseContrast { flatSurface } }
            .overlay { shape.strokeBorder(Color.primary.opacity(model.increaseContrast ? 0.55 : 0.12), lineWidth: model.increaseContrast ? 1.5 : 1) }
            .clipShape(shape)
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onSize)
            // The live panel is sized by `onSize`; in a larger frame the capsule stays centred.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var flatSurface: some View { shape.fill(HUDColors.surface) }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                indicator
                    .accessibilityHidden(true)
                Text(model.status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.isError ? HUDColors.error : Color.primary)
                    .lineLimit(3)
                    .frame(width: HUDText.fittedWidth(model.status, font: .systemFont(ofSize: 13, weight: .medium), max: Self.maxTextWidth - 90),
                           alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.cleaned {
                    Label("cleaned", systemImage: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(HUDColors.action.opacity(0.16), in: Capsule())
                        .foregroundStyle(HUDColors.action)
                        .lineLimit(1)
                        .fixedSize()
                }
                if model.showUseRaw {
                    Button("Use raw") { model.onUseRaw?() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HUDColors.action)
                        .fixedSize()
                }
                if model.debugRetention {
                    Text("DEBUG: recordings kept")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(HUDColors.badge, in: Capsule())
                        .foregroundStyle(.white)
                        .fixedSize()
                }
            }
            let shown = HUDText.tail(stable: model.stable, unstable: model.unstable)
            if !shown.stable.isEmpty || !shown.unstable.isEmpty {
                (Text(shown.stable) + Text(shown.unstable).foregroundStyle(Color.primary.opacity(model.increaseContrast ? 0.72 : 0.5)))
                    .font(.system(size: 15))
                    .lineLimit(4)
                    .frame(width: HUDText.fittedWidth(shown.stable + shown.unstable, font: .systemFont(ofSize: 15), max: Self.maxTextWidth),
                           alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var indicator: some View {
        if let symbol = model.indicator.symbol {
            Image(systemName: symbol.name)
                .font(.system(size: 15))
                .foregroundStyle(model.isError ? HUDColors.error : model.indicator == .success ? Color.green : Color.secondary)
                .frame(width: 20, height: 20)
        } else if model.indicator == .waveform {
            WaveformView(levels: model.levels, animated: !model.reduceMotion)
        }
    }
}

/// A live waveform: one bar per recent input level, scrolling left as new levels arrive. Reduce Motion shows steady,
/// even bars instead of moving ones.
struct WaveformView: View {
    static let width: CGFloat = 16 * 2.5 + 15 * 1.5
    let levels: LevelHistory
    let animated: Bool

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<LevelHistory.capacity, id: \.self) { i in
                let level = animated ? CGFloat(levels.samples[i]) : 0.25
                Capsule()
                    .fill(Color.primary.opacity(animated ? 0.3 + 0.7 * Double(i + 1) / Double(LevelHistory.capacity) : 0.45))
                    .frame(width: 2.5, height: 3 + 17 * level)
            }
        }
        .frame(width: Self.width, height: 20)
        .animation(animated ? .easeOut(duration: 0.08) : nil, value: levels)
    }
}

/// What the HUD says after an insertion, and for how long. Pure, so it is unit-tested and the snapshots show real wording.
public struct OutcomePresentation: Equatable, Sendable {
    public var status: String
    public var indicator: HUDIndicator = .success
    public var isError = false
    public var showUseRaw = false
    /// The text was rewritten by clean-up: the HUD shows a small "cleaned" badge.
    public var cleaned = false
    /// Seconds the HUD stays up.
    public var linger: Double

    /// `offerRaw` is the "Show raw after clean-up" preference: off keeps the badge but drops the Use raw button.
    public static func of(_ outcome: InsertionOutcome, final: FinalResult, offerRaw: Bool = true) -> OutcomePresentation {
        let useRaw = final.canUseRaw && offerRaw
        return switch outcome {
        case .inserted:
            OutcomePresentation(status: "Inserted", showUseRaw: useRaw,
                                cleaned: final.canUseRaw, linger: useRaw ? 5 : final.canUseRaw ? 1.8 : 1.2)
        case .copied:
            OutcomePresentation(status: "Copied — ⌘V", indicator: .clipboard, cleaned: final.canUseRaw, linger: 3)
        case .insertedUnverified:
            OutcomePresentation(status: "Inserted? ⌘V if empty", indicator: .clipboard, cleaned: final.canUseRaw, linger: 4)
        case .refusedSecure:
            OutcomePresentation(status: "Secure field — not inserted", indicator: .warning, isError: true, linger: 3)
        }
    }
}

public enum HUDText {
    /// The width a line of text wants, capped at `max`. SwiftUI proposes no width to a fixed-size capsule, so a Text
    /// would never wrap; giving it this width makes the HUD hug short text and wrap long text at the maximum.
    @MainActor
    public static func fittedWidth(_ text: String, font: NSFont, max limit: CGFloat) -> CGFloat {
        let natural = NSAttributedString(string: text, attributes: [.font: font]).size().width
        return min(limit, ceil(natural) + 2)
    }

    /// Long dictation keeps only the newest words, so the live end of the text is always visible. SwiftUI's own
    /// head truncation would keep the *oldest* lines and cut the last line mid-word.
    /// Drops from the front at a word boundary and marks the cut with "…". The stable/unstable split is kept.
    public static func tail(stable: String, unstable: String, limit: Int = 200) -> (stable: String, unstable: String) {
        let total = stable.count + unstable.count
        guard total > limit else { return (stable, unstable) }
        let combined = stable + unstable
        var cut = combined.index(combined.startIndex, offsetBy: total - limit)
        // Move the cut forward to just after the next space so no word is left half-visible.
        if let space = combined[cut...].firstIndex(of: " ") {
            let after = combined.index(after: space)
            if after < combined.endIndex { cut = after }
        }
        let dropped = combined.distance(from: combined.startIndex, to: cut)
        if dropped >= stable.count {
            return ("", "…" + String(combined[cut...]))
        }
        return ("…" + String(combined[cut...].prefix(stable.count - dropped)), unstable)
    }
}

/// System red fails WCAG contrast on the HUD's translucent material (about 2:1 in light, 2.5:1 in dark),
/// so the HUD uses its own reds, checked against representative material colours in the tests.
public enum HUDColors {
    public typealias RGB = (r: Double, g: Double, b: Double)
    public static let errorLight: RGB = (0.62, 0.04, 0.04)
    public static let errorDark: RGB = (1.0, 0.70, 0.66)
    /// Background of the white "DEBUG: recordings kept" badge.
    public static let badgeRGB: RGB = (0.72, 0.07, 0.07)

    /// The "Use raw" button; the system accent blue is about 2.7:1 on the light material.
    public static let actionLight: RGB = (0.0, 0.30, 0.75)
    public static let actionDark: RGB = (0.62, 0.80, 1.0)

    private static func dynamic(light: RGB, dark: RGB) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }
    /// The opaque stand-in for the HUD material (Increase Contrast, snapshots), a touch translucent like the material.
    public static let surfaceLight: RGB = (0.97, 0.97, 0.98)
    public static let surfaceDark: RGB = (0.16, 0.16, 0.18)
    public static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let c = dark ? surfaceDark : surfaceLight
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 0.94)
    })
    public static let error = dynamic(light: errorLight, dark: errorDark)
    public static let action = dynamic(light: actionLight, dark: actionDark)
    public static let badge = Color(red: badgeRGB.r, green: badgeRGB.g, blue: badgeRGB.b)
}
