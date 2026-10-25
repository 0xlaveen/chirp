import Foundation
import Testing
@testable import ChirpIOSCore

/// The Pond tokens pinned to the #151 §C table (the values the Mac's `ChirpUI/Theme.swift` and Android's
/// `ui/ChirpTheme.kt` use), so iOS can't drift from the other two apps, and their WCAG contrast.
@Suite struct PondTests {
    private func hex(_ c: ChirpColor.RGB) -> UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32((v * 255).rounded()) }
        return byte(c.r) << 16 | byte(c.g) << 8 | byte(c.b)
    }

    private func luminance(_ c: ChirpColor.RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func contrast(_ a: ChirpColor.RGB, _ b: ChirpColor.RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    typealias Token = (light: ChirpColor.RGB, dark: ChirpColor.RGB)

    @Test func tokensMatchTheSpecTable() {
        let table: [(String, Token, UInt32, UInt32)] = [
            ("background", ChirpColor.Pond.background, 0xF6F7FA, 0x0D1526),
            ("surface", ChirpColor.Pond.surface, 0xFFFFFF, 0x121C30),
            ("surfaceRaised", ChirpColor.Pond.surfaceRaised, 0xECEFF5, 0x1A2640),
            ("ink", ChirpColor.Pond.ink, 0x1A2333, 0xE8ECF3),
            ("inkMuted", ChirpColor.Pond.inkMuted, 0x5B6577, 0xA3ADBF),
            ("koi", ChirpColor.Pond.koi, 0xC2410C, 0xFF8A4C),
            ("koiDecor", ChirpColor.Pond.koiDecor, 0xF26A1B, 0xFF8A4C),
            ("koiContainer", ChirpColor.Pond.koiContainer, 0xFFE4D4, 0x5C2207),
            ("onKoiContainer", ChirpColor.Pond.onKoiContainer, 0x7A2A08, 0xFFD9C2),
            ("onKoi", ChirpColor.Pond.onKoi, 0xFFFFFF, 0x0D1526),
            ("moon", ChirpColor.Pond.moon, 0x8A5A00, 0xF5C566),
            ("moonFill", ChirpColor.Pond.moonFill, 0xF5C566, 0xF5C566),
            ("lily", ChirpColor.Pond.lily, 0x2F7A4F, 0x7CCB9B),
            ("record", ChirpColor.Pond.record, 0xD93636, 0xFF6B6B),
            // Android's tertiaryContainer / onTertiaryContainer, the warning banner on all three.
            ("warningContainer", ChirpColor.Pond.warningContainer, 0xF5C566, 0x4E3B00),
            ("onWarningContainer", ChirpColor.Pond.onWarningContainer, 0x402D00, 0xF5C566),
        ]
        for (name, token, light, dark) in table {
            #expect(hex(token.light) == light, "\(name) light")
            #expect(hex(token.dark) == dark, "\(name) dark")
        }
    }

    @Test func textTokensMeetWCAGAAOnBackgroundAndSurface() {
        let surfaces: [Token] = [ChirpColor.Pond.background, ChirpColor.Pond.surface]
        let text: [(String, Token)] = [("ink", ChirpColor.Pond.ink), ("inkMuted", ChirpColor.Pond.inkMuted),
                                       ("koi", ChirpColor.Pond.koi), ("moon", ChirpColor.Pond.moon),
                                       ("lily", ChirpColor.Pond.lily)]
        for surface in surfaces {
            for (name, token) in text {
                #expect(contrast(token.light, surface.light) >= 4.5, "\(name) on light \(hex(surface.light))")
                #expect(contrast(token.dark, surface.dark) >= 4.5, "\(name) on dark \(hex(surface.dark))")
            }
        }
    }

    @Test func filledTokensKeepTheirTextReadable() {
        let pairs: [(String, Token, Token)] = [
            ("onKoi on koi", ChirpColor.Pond.onKoi, ChirpColor.Pond.koi),
            ("onKoiContainer on koiContainer", ChirpColor.Pond.onKoiContainer, ChirpColor.Pond.koiContainer),
            ("onWarningContainer on warningContainer", ChirpColor.Pond.onWarningContainer, ChirpColor.Pond.warningContainer),
        ]
        for (name, ink, fill) in pairs {
            #expect(contrast(ink.light, fill.light) >= 4.5, "\(name) light")
            #expect(contrast(ink.dark, fill.dark) >= 4.5, "\(name) dark")
        }
    }

    /// `record` is the record/stop dot and the Stop fill, not body text: WCAG AA for UI components is 3:1.
    @Test func recordStandsOutAsAUIComponent() {
        for surface in [ChirpColor.Pond.background, ChirpColor.Pond.surface] {
            #expect(contrast(ChirpColor.Pond.record.light, surface.light) >= 3)
            #expect(contrast(ChirpColor.Pond.record.dark, surface.dark) >= 3)
        }
    }

    @Test func ripplePeriodShrinksAsSpeechPeaks() {
        #expect(Ripple.period(level: 0) == Ripple.periodAtSilence)
        #expect(Ripple.periodAtSilence == 1.6 && Ripple.periodAtPeak == 0.6)
        #expect(abs(Ripple.period(level: 1) - 0.6) < 1e-9)
        #expect(abs(Ripple.period(level: 0.5) - 1.1) < 1e-9)
        #expect(Ripple.period(level: 0.8) < Ripple.period(level: 0.2))
        #expect(abs(Ripple.period(level: 2) - 0.6) < 1e-9, "levels clamp high")
        #expect(abs(Ripple.period(level: -1) - 1.6) < 1e-9, "levels clamp low")
    }

    @Test func rippleClockPhaseAdvancesWithinOneCycle() {
        let base = Date(timeIntervalSinceReferenceDate: 100)
        for level in [0.0, 0.35, 1.0] {
            let period = Ripple.period(level: level)
            let before = Ripple.clockPhase(at: base, level: level)
            let after = Ripple.clockPhase(at: base.addingTimeInterval(period / 2), level: level)
            #expect((0..<1).contains(before))
            #expect(abs(abs(after - before) - 0.5) < 1e-6, "level \(level)")
        }
    }

    @Test func guttersAndRadiiFollowTheGrid() {
        #expect(ChirpSpacing.gutter(.compact) == 16 && ChirpSpacing.gutter(nil) == 16)
        #expect(ChirpSpacing.gutter(.regular) == 24)
        #expect([ChirpSpacing.s4, ChirpSpacing.s8, ChirpSpacing.s12, ChirpSpacing.s16, ChirpSpacing.s24,
                 ChirpSpacing.s32, ChirpSpacing.s48] == [4, 8, 12, 16, 24, 32, 48])
        #expect([ChirpRadius.control, ChirpRadius.row, ChirpRadius.panel, ChirpRadius.sheet] == [6, 10, 16, 28])
    }
}
