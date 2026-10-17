import AppKit
import ChirpCore
import Observation
import SwiftUI

/// What the leading symbol of the HUD shows: the live waveform while listening, otherwise the outcome.
public enum HUDIndicator: Equatable, Sendable {
    case waveform, success, clipboard, warning, none
    /// Clean-up is running or just finished: a sparkle, which moves unless Reduce Motion is on.
    case sparkle

    var symbol: (name: String, label: String)? {
        switch self {
        case .waveform, .none, .sparkle: nil
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
    public static let polishing = "Polishing…"
    public static let polished = "Polished"
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
    /// The clean-up style in use ("Email"), shown as a small chip.
    public var styleName: String?
    /// The raw transcript is on screen as solid text while clean-up runs: a shimmer sweeps across it.
    public var polishing = false
    /// A fixed shimmer position (0...1) for the snapshots; nil lets the shimmer run on the clock.
    public var shimmerPhase: Double?
    /// The brief highlight of what clean-up changed, in reading order; nil outside that moment.
    public var diff: [WordDiff.Segment]?
    /// How far the removed words have faded, 0 (struck through, fully visible) to 1 (gone).
    public var diffFade = 0.0
    /// Clean-up did not deliver, so the raw transcript was kept: a small "kept original" note.
    public var keptOriginal = false
    /// System display options, read each time the HUD is shown.
    public var reduceMotion = false
    public var increaseContrast = false
    /// Draws an opaque stand-in for the blur: used for Increase Contrast and the offscreen snapshots, which have no
    /// window to blur through. The live panel's translucency is an `NSVisualEffectView` behind this view.
    public var flatSurface = false
    public var onUseRaw: (() -> Void)?

    public init() {}

    public func pushLevel(_ rms: Float) { levels.push(rms: rms) }

    /// Clean-up started: the raw transcript stays on screen as solid text with a shimmer and the "Polishing…" status.
    public func beginPolishing(raw: String, style: String?) {
        if let style { styleName = style }
        status = HUDStatus.polishing
        indicator = .sparkle
        isError = false
        stable = raw
        unstable = ""
        withAnimation(.easeInOut(duration: 0.2)) { polishing = true }
    }

    /// The cleaned text arrived: crossfade to it with the changes highlighted (removed words struck through and fading,
    /// changed words tinted) for `OutcomePresentation.highlightDuration`, then settle on the plain cleaned text.
    /// Without a usable diff (or nothing changed) it is a plain crossfade. Reduce Motion shows the highlight without the fade.
    public func playChangeHighlight(raw: String, cleaned: String) async {
        let segments = WordDiff.segments(raw: raw, cleaned: cleaned)
        status = HUDStatus.polished
        indicator = .sparkle
        if let segments {
            diffFade = 0
            withAnimation(.easeInOut(duration: 0.22)) { polishing = false; diff = segments }
            let total = OutcomePresentation.highlightDuration
            if reduceMotion {
                try? await Task.sleep(for: .seconds(total))
            } else {
                // Hold the strike-through for a beat, then fade the removed words out; the model is stepped by hand
                // because a concatenated Text cannot animate individual runs.
                let hold = 0.3, steps = 12, fadeTime = total - hold
                try? await Task.sleep(for: .seconds(hold))
                for step in 1...steps {
                    diffFade = Double(step) / Double(steps)
                    try? await Task.sleep(for: .seconds(fadeTime / Double(steps)))
                }
            }
        } else {
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.2 : 0.3))
        }
        settle(on: cleaned)
    }

    /// Shows `text` as plain solid text: no shimmer, no highlight.
    public func settle(on text: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            polishing = false
            diff = nil
            diffFade = 0
            stable = text
            unstable = ""
        }
    }
    public func silence() { levels.clear() }

    public func reset() {
        status = ""; stable = ""; unstable = ""; levels.clear(); indicator = .waveform
        isError = false; showUseRaw = false; cleaned = false; onUseRaw = nil
        styleName = nil; polishing = false; diff = nil; diffFade = 0; keptOriginal = false
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
                if let name = model.styleName {
                    Text(name)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(model.increaseContrast ? 0.16 : 0.1), in: Capsule())
                        .foregroundStyle(Color.primary.opacity(model.increaseContrast ? 0.9 : 0.7))
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel("Style: \(name)")
                }
                if model.keptOriginal {
                    Text("kept original")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                        .foregroundStyle(Color.primary.opacity(model.increaseContrast ? 0.9 : 0.7))
                        .lineLimit(1)
                        .fixedSize()
                }
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
            if let diff = model.diff {
                DiffText(segments: diff, fade: model.diffFade, contrast: model.increaseContrast)
                    .frame(width: HUDText.fittedWidth(DiffText.plain(diff), font: .systemFont(ofSize: 15), max: Self.maxTextWidth),
                           alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else if model.polishing, !shown.stable.isEmpty || !shown.unstable.isEmpty {
                ShimmerText(text: shown.stable + shown.unstable, animated: !model.reduceMotion, phase: model.shimmerPhase)
                    .frame(width: HUDText.fittedWidth(shown.stable + shown.unstable, font: .systemFont(ofSize: 15), max: Self.maxTextWidth),
                           alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else if !shown.stable.isEmpty || !shown.unstable.isEmpty {
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
        } else if model.indicator == .sparkle {
            Image(systemName: "sparkles")
                .font(.system(size: 15))
                .foregroundStyle(HUDColors.action)
                .symbolEffect(.pulse, options: .repeating, isActive: !model.reduceMotion)
                .frame(width: 20, height: 20)
        }
    }
}

/// The raw transcript as solid text while clean-up runs. A soft highlight sweeps across it (a still sparkle in the
/// header and no sweep when Reduce Motion is on), so the HUD never looks stuck.
struct ShimmerText: View {
    let text: String
    let animated: Bool
    /// Pins the sweep for the snapshots.
    var phase: Double?

    private static let period = 1.5

    var body: some View {
        if animated, phase == nil {
            TimelineView(.animation) { context in
                sweep(at: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period)
            }
        } else {
            sweep(at: animated ? (phase ?? 0) : nil)
        }
    }

    private var label: some View { Text(text).font(.system(size: 15)).lineLimit(4) }

    @ViewBuilder private func sweep(at position: Double?) -> some View {
        if let position {
            label
                .overlay {
                    // A narrow band travelling from beyond the left edge to beyond the right one.
                    GeometryReader { geo in
                        let band = max(40, geo.size.width * 0.28)
                        let x = -band + (geo.size.width + 2 * band) * position
                        LinearGradient(colors: [.clear, HUDColors.shimmer, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: x)
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                }
        } else {
            label
        }
    }
}

/// The brief highlight of what clean-up changed: the cleaned text with removed raw words struck through and fading out,
/// and changed or added words gently tinted.
struct DiffText: View {
    let segments: [WordDiff.Segment]
    let fade: Double
    let contrast: Bool

    /// The text without the removed words (the width the HUD settles at); removed words add width while visible.
    static func plain(_ segments: [WordDiff.Segment]) -> String { segments.map(\.text).joined(separator: " ") }

    var body: some View {
        segments.enumerated().reduce(Text("")) { acc, item in
            let (i, seg) = item
            let space = i == 0 ? "" : " "
            switch seg.kind {
            case .same:
                return acc + Text(space + seg.text)
            case .changed, .added:
                return acc + Text(space) + Text(seg.text).foregroundStyle(HUDColors.change)
            case .removed:
                // Removed words fade out and, once gone, take no room.
                guard fade < 0.97 else { return acc }
                return acc + Text(space) + Text(seg.text).strikethrough().foregroundStyle(Color.primary.opacity((contrast ? 0.75 : 0.55) * (1 - fade)))
            }
        }
        .font(.system(size: 15))
        .lineLimit(4)
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
    /// Clean-up was asked for but did not deliver (timeout, error, rejected answer): the raw text was kept.
    public var keptOriginal = false
    /// Use raw is offered outside the HUD for `RawOffer.duration` (⌃⌥Z and the menu).
    public var offersRawOutsideHUD = false
    /// Seconds the HUD stays up. 0 fades it out at once.
    public var linger: Double

    /// How long the diff highlight shows before the cleaned text is inserted.
    public static let highlightDuration = 0.8

    /// The note when clean-up did not deliver and the raw text was kept stays up this long at most.
    public static let keptNoteLinger = 1.0

    /// `offerRaw` is the "Show raw after clean-up" preference: off drops "Use raw" altogether. `showChanges` is "Show
    /// changes after clean-up": on keeps the HUD up with the diff and the Use raw button; off (the default) fades the
    /// HUD out at once after a cleaned insertion and offers Use raw outside it.
    public static func of(_ outcome: InsertionOutcome, final: FinalResult, offerRaw: Bool = true,
                          showChanges: Bool = false) -> OutcomePresentation {
        let useRaw = final.canUseRaw && offerRaw
        let kept = !final.corrected && final.correctionError != nil
        return switch outcome {
        case .inserted where showChanges:
            OutcomePresentation(status: "Inserted", showUseRaw: useRaw, cleaned: final.canUseRaw, keptOriginal: kept,
                                linger: useRaw ? 5 : final.canUseRaw ? 1.8 : kept ? keptNoteLinger : 1.2)
        case .inserted:
            OutcomePresentation(status: "Inserted", cleaned: final.canUseRaw, keptOriginal: kept,
                                offersRawOutsideHUD: useRaw, linger: final.canUseRaw ? 0 : kept ? keptNoteLinger : 1.2)
        case .copied:
            OutcomePresentation(status: "Copied — ⌘V", indicator: .clipboard, cleaned: final.canUseRaw, keptOriginal: kept, linger: 3)
        case .insertedUnverified:
            OutcomePresentation(status: "Inserted? ⌘V if empty", indicator: .clipboard, cleaned: final.canUseRaw, keptOriginal: kept, linger: 4)
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
    /// Changed words in the clean-up highlight: the action blue, a little lighter than the "Use raw" button.
    public static let change = action
    /// The shimmer's highlight band: the accent blue, so the sweep reads against the solid text.
    public static let shimmer = action.opacity(0.9)
}
