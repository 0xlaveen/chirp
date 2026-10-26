import Foundation
import Security
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Legacy voiceprint math and the Keychain source used only for migration (#247 item 3b).

private func unit(_ i: Int) -> [Float] { var v = [Float](repeating: 0, count: 256); v[i] = 1; return v }
/// A voice whose cosine to `unit(i)` is `cos` (the rest along `unit(j)`).
private func near(_ i: Int, _ j: Int, _ cos: Float) -> [Float] { var v = unit(i); v[i] = cos; v[j] = (1 - cos * cos).squareRoot(); return v }
private func heard(_ e: [Float], _ seconds: TimeInterval) -> Voiceprint { var p = Voiceprint(); p.add(e, seconds: seconds); return p }

@Suite struct VoiceprintTests {
    @Test func aVoiceprintIsTheSpeechWeightedMean() {
        var p = heard(unit(0), 3)
        p.add(unit(1), seconds: 1)
        #expect(p.seconds == 4)
        #expect(abs(Voiceprint.cosine(p.centroid, unit(0)) - 3 / Float(10).squareRoot()) < 1e-5)
        var q = Voiceprint()
        q.add(p)
        q.add([Float](repeating: .nan, count: 256), seconds: 5)    // a broken embedding is ignored
        q.add(unit(0), seconds: 0)
        #expect(q == p)
        #expect(Voiceprint.cosine([1, 0], [1, 0, 0]) == -1)
    }

    @Test func matchingNeedsTheThresholdTheMarginEnoughSpeechAndTheSameModel() {
        let maya = VoiceProfile(name: "Maya", embedding: unit(0), model: "m", seconds: 30)
        let theo = VoiceProfile(name: "Theo", embedding: unit(1), model: "m", seconds: 30)
        let old = VoiceProfile(name: "Ana", embedding: unit(2), model: "old", seconds: 30)
        let voices: [Int: Voiceprint] = [
            1: heard(near(0, 9, 0.9), 12),                          // Maya
            2: heard(near(1, 9, 0.6), 40),                          // not alike enough
            3: heard(unit(0), 5),                                   // too little speech
            4: heard(Voiceprint(sum: unit(0).enumerated().map { $1 + ($0 == 1 ? 1 : 0) }).centroid, 20),  // between two: no margin
            5: heard(unit(2), 30),                                  // only an old-model profile
        ]
        #expect(VoiceMatch.suggest(voices, profiles: [maya, theo, old], model: "m") == [1: maya.id])
        // One profile, two candidates: the closer one gets it.
        let two: [Int: Voiceprint] = [1: heard(near(0, 9, 0.8), 12), 2: heard(near(0, 9, 0.95), 12)]
        #expect(VoiceMatch.suggest(two, profiles: [maya], model: "m") == [2: maya.id])
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_KEYCHAIN_TESTS"] == "1")) struct KeychainVoiceProfileTests {
    @Test func profilesRoundTripNeverSyncAndForgetDeletesThem() throws {
        let store = KeychainVoiceProfileStore(service: "Chirp Voice Profile Test \(UUID().uuidString)")
        defer { try? store.deleteAll() }
        let maya = VoiceProfile(name: "Maya", embedding: unit(3), model: "m", seconds: 30, created: Date(timeIntervalSince1970: 1))
        let theo = VoiceProfile(name: "Theo", embedding: unit(4), model: "m", seconds: 21, created: Date(timeIntervalSince1970: 2))
        try store.save(maya)
        try store.save(theo)
        var renamed = maya
        renamed.seconds = 45
        try store.save(renamed)
        #expect(try store.load() == [renamed, theo])
        // The item is not synchronizable (asked for explicitly: a synchronizable copy would not match).
        var result: AnyObject?
        let status = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
                                          kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                                          kSecMatchLimit as String: kSecMatchLimitAll,
                                          kSecReturnAttributes as String: true] as CFDictionary, &result)
        #expect(status == errSecSuccess)
        let items = try #require(result as? [[String: Any]])
        #expect(items.count == 2 && items.allSatisfy { ($0[kSecAttrSynchronizable as String] as? Bool ?? false) == false })
        try store.delete(maya.id)
        #expect(try store.load() == [theo])
        try store.deleteAll()
        #expect(try store.load().isEmpty)
    }
}
