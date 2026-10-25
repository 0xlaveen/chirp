import Foundation
import SwiftUI
import Testing
@testable import ChirpIOSCore

/// The iOS Pond tokens, pinned to the #151 §C table (the same values as `mac/Sources/ChirpUI/Theme.swift`
/// and Android's `ChirpTheme.kt`) so the three platforms can't drift, plus WCAG AA contrast the way Mac's
/// `ChirpThemeTests` computes it.
struct PondTests {
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

    @Test func everyTokenMatchesTheIssue151Table() {
        typealias Pair = (light: ChirpColor.RGB, dark: ChirpColor.RGB)
        let table: [(name: String, token: Pair, light: UInt32, dark: UInt32)] = [
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
        ]
        for row in table {
            #expect(hex(row.token.light) == row.light, "\(row.name) light")
            #expect(hex(row.token.dark) == row.dark, "\(row.name) dark")
        }
    }

    @Test func textTokensMeetWCAGAAOnBackgroundAndSurface() {
        let surfaces = [ChirpColor.Pond.background, ChirpColor.Pond.surface]
        let textTokens = [("ink", ChirpColor.Pond.ink), ("inkMuted", ChirpColor.Pond.inkMuted), ("koi", ChirpColor.Pond.koi)]
        for surface in surfaces {
            for (name, token) in textTokens {
                #expect(contrast(token.light, surface.light) >= 4.5, "\(name) on light \(hex(surface.light))")
                #expect(contrast(token.dark, surface.dark) >= 4.5, "\(name) on dark \(hex(surface.dark))")
            }
        }
    }

    @Test func koiFillsKeepTheirTextReadable() {
        #expect(contrast(ChirpColor.Pond.onKoi.light, ChirpColor.Pond.koi.light) >= 4.5)
        #expect(contrast(ChirpColor.Pond.onKoi.dark, ChirpColor.Pond.koi.dark) >= 4.5)
        #expect(contrast(ChirpColor.Pond.onKoiContainer.light, ChirpColor.Pond.koiContainer.light) >= 4.5)
        #expect(contrast(ChirpColor.Pond.onKoiContainer.dark, ChirpColor.Pond.koiContainer.dark) >= 4.5)
    }

    /// Moon and lily carry text too (Polished, Connected, done checks).
    @Test func moonAndLilyReadAsTextOnSurfaces() {
        for surface in [ChirpColor.Pond.background, ChirpColor.Pond.surface] {
            for token in [ChirpColor.Pond.moon, ChirpColor.Pond.lily] {
                #expect(contrast(token.light, surface.light) >= 4.5)
                #expect(contrast(token.dark, surface.dark) >= 4.5)
            }
        }
    }

    /// `record` is the record/stop dot and error colour: WCAG AA for UI components is 3:1.
    @Test func recordStandsOutOnBackground() {
        #expect(contrast(ChirpColor.Pond.record.light, ChirpColor.Pond.background.light) >= 3)
        #expect(contrast(ChirpColor.Pond.record.dark, ChirpColor.Pond.background.dark) >= 3)
    }

    @Test func ripplePeriodShrinksAsSpeechPeaks() {
        #expect(Ripple.period(level: 0) == Ripple.periodAtSilence)
        #expect(Ripple.periodAtSilence == 1.6 && Ripple.periodAtPeak == 0.6)
        #expect(abs(Ripple.period(level: 1) - Ripple.periodAtPeak) < 1e-9)
        #expect(abs(Ripple.period(level: 0.5) - 1.1) < 1e-9)
        #expect(Ripple.period(level: 0.8) < Ripple.period(level: 0.2))
        #expect(abs(Ripple.period(level: 2) - Ripple.periodAtPeak) < 1e-9, "levels clamp")
        #expect(Ripple.period(level: -1) == Ripple.periodAtSilence, "levels clamp")
    }

    @Test func rippleClockPhaseStaysWithinOneCycle() {
        let base = Date(timeIntervalSinceReferenceDate: 100)
        for level in [0.0, 0.35, 1.0] {
            let period = Ripple.period(level: level)
            let before = Ripple.clockPhase(at: base, level: level)
            let after = Ripple.clockPhase(at: base.addingTimeInterval(period / 2), level: level)
            #expect((0..<1).contains(before) && (0..<1).contains(after), "level \(level)")
            #expect(abs(abs(after - before) - 0.5) < 1e-6, "level \(level)")  // half a cycle on, wrapping either way
        }
    }

    @Test func gutterIs16OnPhoneAnd24AtRegularWidth() {
        #expect(ChirpSpacing.gutter(.compact) == 16)
        #expect(ChirpSpacing.gutter(nil) == 16)
        #expect(ChirpSpacing.gutter(.regular) == 24)
    }
}
