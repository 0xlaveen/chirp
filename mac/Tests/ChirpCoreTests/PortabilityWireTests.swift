import Foundation
import Testing
@testable import ChirpCore

struct PortabilityWireTests {
    @Test func explicitlyEmptyPromptSurvivesWireEncoding() throws {
        let json = ClientMessage.start(StartOptions(correctionPrompt: ""))
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["correction_prompt"] as? String == "")
        let absent = ClientMessage.start(StartOptions())
        #expect(!absent.contains("correction_prompt"))
        let whitespace = ClientMessage.start(StartOptions(correctionPrompt: "  "))
        let spaced = try #require(JSONSerialization.jsonObject(with: Data(whitespace.utf8)) as? [String: Any])
        #expect(spaced["correction_prompt"] as? String == "  ")
    }
    @Test func unicodeScalarLimitsMatchPythonWithoutBreakingGraphemes() throws {
        let family = "👩‍👩‍👧‍👦"
        #expect(family.count == 1 && family.unicodeScalars.count == 7)
        let prompt = CorrectionProfile.clampPrompt(String(repeating: family, count: 4000))
        #expect(prompt.unicodeScalars.count <= 4000 && prompt.count == 571)
        #expect(CorrectionProfile.clampPrompt(family, limit: 6).isEmpty)
        #expect(CorrectionProfile.clampPrompt("test", limit: -1).isEmpty)
        let instructions = try #require(CorrectionProfile.clamp(String(repeating: "e\u{301}", count: 2000)))
        #expect(instructions.unicodeScalars.count == 2000 && instructions.count == 1000)
    }
}
