import ChirpCore
import Observation
import SwiftUI

@MainActor @Observable
public final class HUDModel {
    public var status = ""
    public var stable = ""
    public var unstable = ""
    public var level: Float = 0
    public var debugRetention = false
    public var isError = false
    public var showUseRaw = false
    /// The inserted text was rewritten by the server's clean-up.
    public var cleaned = false
    public var reduceMotion = false
    public var onUseRaw: (() -> Void)?

    public init() {}

    public func reset() {
        status = ""; stable = ""; unstable = ""; level = 0
        isError = false; showUseRaw = false; cleaned = false; onUseRaw = nil
    }
}

public struct HUDView: View {
    let model: HUDModel
    let onSize: (CGSize) -> Void

    public init(model: HUDModel, onSize: @escaping (CGSize) -> Void = { _ in }) {
        self.model = model
        self.onSize = onSize
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LevelMeter(level: model.level, animated: !model.reduceMotion)
                    .accessibilityHidden(true)
                Text(model.status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.isError ? HUDColors.error : Color.secondary)
                Spacer(minLength: 0)
                if model.cleaned {
                    Label("cleaned", systemImage: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(HUDColors.action.opacity(0.14), in: Capsule())
                        .foregroundStyle(HUDColors.action)
                }
                if model.showUseRaw {
                    Button("Use raw") { model.onUseRaw?() }.buttonStyle(.borderless).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HUDColors.action)
                }
            }
            if model.debugRetention {
                Text("DEBUG: recordings kept")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(HUDColors.badge, in: Capsule())
                    .foregroundStyle(.white)
            }
            let shown = HUDText.tail(stable: model.stable, unstable: model.unstable)
            if !shown.stable.isEmpty || !shown.unstable.isEmpty {
                (Text(shown.stable) + Text(shown.unstable).foregroundStyle(Color.primary.opacity(0.5)))
                    .font(.system(size: 15))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .accessibilityElement(children: .contain)
        .padding(14)
        .frame(width: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        .padding(10)   // room for the shadow inside the panel
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onSize)
    }
}

private struct LevelMeter: View {
    let level: Float
    let animated: Bool
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                let on = Float(i) / 8 < min(1, level * 6)
                Capsule().fill(on ? Color.green : Color.primary.opacity(0.15)).frame(width: 3, height: 12)
            }
        }
        .animation(animated ? .linear(duration: 0.05) : nil, value: level)
    }
}


/// What the HUD says after an insertion, and for how long. Pure, so it is unit-tested and the snapshots show real wording.
public struct OutcomePresentation: Equatable, Sendable {
    public var status: String
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
        case .inserted(let method):
            OutcomePresentation(status: method == .ax ? "Inserted" : "Inserted (paste)", showUseRaw: useRaw,
                                cleaned: final.canUseRaw, linger: useRaw ? 5 : final.canUseRaw ? 1.8 : 1.2)
        case .copied:
            OutcomePresentation(status: "Copied — press ⌘V", cleaned: final.canUseRaw, linger: 3)
        case .insertedUnverified:
            OutcomePresentation(status: "Inserted? If nothing appeared, press ⌘V", cleaned: final.canUseRaw, linger: 4)
        case .refusedSecure:
            OutcomePresentation(status: "Secure field — nothing inserted", isError: true, linger: 3)
        }
    }
}

public enum HUDText {
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
    public static let error = dynamic(light: errorLight, dark: errorDark)
    public static let action = dynamic(light: actionLight, dark: actionDark)
    public static let badge = Color(red: badgeRGB.r, green: badgeRGB.g, blue: badgeRGB.b)
}
