import AppKit
import ChirpCore
import Testing
@testable import ChirpUI

@MainActor
@Suite struct MacParityTests {
    @Test func speakerPaletteMatchesTheSharedPondEightPairs() {
        // Pin the same table as ios/Shared/Sources/ChirpIOSCore/Speakers.swift (and Android SpeakerColors).
        let pairs: [(UInt32, UInt32)] = [
            (0xC2410C, 0xFF8A4C), (0x2F7A4F, 0x7CCB9B), (0x4F46E5, 0xA5B4FC), (0xA21CAF, 0xF0ABFC),
            (0x0F766E, 0x5EEAD4), (0x8A5A00, 0xF5C566), (0x0369A1, 0x7DD3FC), (0xBE123C, 0xFDA4AF)
        ]
        #expect(SpeakerPalette.light.count == 8 && SpeakerPalette.dark.count == 8)
        for (i, pair) in pairs.enumerated() {
            for (actual, hex) in [(SpeakerPalette.light[i], pair.0), (SpeakerPalette.dark[i], pair.1)] {
                let expected = ChirpColor.hex(hex)
                #expect(actual.r == expected.r && actual.g == expected.g && actual.b == expected.b)
            }
        }
        #expect(SpeakerPalette.tint.light == 0.12 && SpeakerPalette.tint.dark == 0.18)
    }

    @Test func serverCopyFollowsTheConfiguredAddress() {
        #expect(VoiceProfilesText.unsupported(local: true) == "Update Chirp on this Mac to save voices")
        #expect(VoiceProfilesText.unsupported(local: false) == "Update your Chirp server to save voices")
        #expect(VoiceText.consentDetail("Maya", local: true).contains("stay on this Mac"))
        #expect(VoiceText.consentDetail("Maya", local: false).contains("stay on your Chirp server"))
        #expect(VoiceProfilesText.forgetDetail("Maya", local: false) == "Removes Maya’s voice from your Chirp server for every device. Names in existing notes stay. This can’t be undone.")
        let health = Health(ok: true, engine: "test", ready: true, correction: "available")
        #expect(SettingsForm.cleanupDetail(health: health, local: false).text.hasPrefix("Runs on your Chirp server:"))
    }
}
