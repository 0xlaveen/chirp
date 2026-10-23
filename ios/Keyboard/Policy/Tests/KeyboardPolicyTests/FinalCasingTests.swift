import Foundation
import Testing
@testable import KeyboardPolicy

/// Ported from Android's FinalCasingTest (#50).
struct FinalCasingTests {
    func mid(_ before: String?) -> Bool { FinalCasing.midSentence(before) }

    @Test func fieldStartBlankAndTerminalsStartASentence() {
        #expect(!mid("") && !mid("   ") && !mid(nil))
        for end in [".", "!", "?", "…", "。", "！", "？", "।", "؟", "‼", "?!"] {
            #expect(!mid("Done\(end)") && !mid("Done\(end) ") && !mid("Done\(end)  "), "after \(end)")
        }
        for br in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"] { #expect(!mid("and then\(br)") && !mid("and then\(br)  ")) }
    }
    @Test func wordsCommasAndDigitsMeanMidSentence() {
        for before in ["and then", "and then ", "first,", "first, ", "first;", "page 3", "x", "été", "日本語", "привет ", "Straße "] {
            #expect(mid(before), "\(before)")
        }
    }
    @Test func closingQuotesLookThroughAndOpenersKeepTheCapital() {
        #expect(!mid("He left.\"") && !mid("He left.” ") && !mid("«Fini.» "))
        #expect(mid("\"hello\"") && mid("“hello” ") && mid("the dogs' "))
        for before in ["said \"", "said “", "(", "see (", "[", "«", "x: ", "x:", "- ", "* ", "• ", "1) ", "> ", "😀 ", "@", "¿"] {
            #expect(!mid(before), "\(before)")
        }
    }
    @Test func onlyCommonFirstWordsAreLowered() {
        #expect(FinalCasing.lowerFirstWord("So we went home.") == "so we went home.")
        #expect(FinalCasing.lowerFirstWord(" And then") == " and then")
        #expect(FinalCasing.lowerFirstWord("It’s fine") == "it’s fine")
        for kept in ["I think so", "I'm here", "Paris is nice", "Monday works", "NASA said", "GitHub is down", "A/B test", "So-called"] {
            #expect(FinalCasing.lowerFirstWord(kept) == kept, "\(kept)")
        }
    }
    @Test func spokenCommandsAreOptInAndOnlyAtTheEnd() {
        #expect(FinalCasing.shape("Okay, new line.", midSentence: false, commands: false) == "Okay, new line.")
        #expect(FinalCasing.shape("Okay, new line.", midSentence: false, commands: true) == "Okay,\n")
        #expect(FinalCasing.shape("New paragraph", midSentence: false, commands: true) == "\n\n")
        #expect(FinalCasing.shape("And then new paragraph!", midSentence: true, commands: true) == "and then\n\n")
        for kept in ["new lines", "a new line of work", "renew line"] {
            #expect(FinalCasing.shape(kept, midSentence: false, commands: true) == kept, "\(kept)")
        }
    }
}

struct CasingInsertionTests {
    let generation = UUID(), utterance = UUID(), now = Date(timeIntervalSince1970: 1_000)
    func event(_ text: String, _ kind: ResultKind, _ sequence: Int, segment: Int = 0) -> TextEvent {
        TextEvent(generation: generation, utteranceID: utterance, kind: kind, text: text, sequence: sequence,
                  createdAt: now, expiresAt: now.addingTimeInterval(30), segment: segment)
    }
    func land(_ policy: inout OwnedInsertion, _ cursor: inout CursorContext, _ e: TextEvent, commands: Bool = false, raw: Bool = false) -> String? {
        guard let plan = policy.plan(e, context: cursor, now: now, leaseUntil: now.addingTimeInterval(60), rawRequested: raw,
                                     commands: commands) else { return nil }
        cursor = plan.resultingContext
        _ = policy.didApply(plan, observed: cursor, now: now)
        return plan.replacement
    }

    @Test func midSentencePartialsAndFinalAgreeSoOnlyTheTailChanges() throws {
        var cursor = CursorContext(documentID: UUID(), before: "We met and", after: "")
        var policy = OwnedInsertion()
        let began1 = policy.begin(generation: generation, utteranceID: utterance, context: cursor, now: now)
        #expect(began1)
        let landed5 = land(&policy, &cursor, event(" Then we left", .partial, 0))
        #expect(landed5 == " then we left")
        let proposed = policy.plan(event(" Then we left.", .final, 1), context: cursor, now: now,
                                   leaseUntil: now.addingTimeInterval(60))
        let final = try #require(proposed)
        #expect(final.replacement == " then we left." && final.deletedText.isEmpty && final.insertedText == ".")
    }

    @Test func sentenceStartsKeepTheCapitalAndRawIsUnshaped() {
        var cursor = CursorContext(documentID: UUID(), before: "Done. ", after: "")
        var policy = OwnedInsertion()
        let began2 = policy.begin(generation: generation, utteranceID: utterance, context: cursor, now: now)
        #expect(began2)
        let landed6 = land(&policy, &cursor, event("So we went.", .final, 0))
        #expect(landed6 == "So we went.")

        var mid = CursorContext(documentID: UUID(), before: "and", after: "")
        var p = OwnedInsertion()
        let began3 = p.begin(generation: generation, utteranceID: utterance, context: mid, now: now)
        #expect(began3)
        let landed7 = land(&p, &mid, event(" So we went, new line", .final, 0), commands: true)
        #expect(landed7 == " so we went,\n")
        let landed8 = land(&p, &mid, event(" So we went, new line", .raw, 1), raw: true)
        #expect(landed8 == " So we went, new line", "Use raw is the server's text")
    }

    @Test func eachLongDictationSegmentIsCasedFromWhereThePreviousEnded() {
        var cursor = CursorContext(documentID: UUID(), before: "", after: "")
        var policy = OwnedInsertion()
        let began4 = policy.begin(generation: generation, utteranceID: utterance, context: cursor, now: now)
        #expect(began4)
        let landed9 = land(&policy, &cursor, event("We planned it,", .final, 0))
        #expect(landed9 == "We planned it,")
        let landed10 = land(&policy, &cursor, event(" And then we shipped it.", .final, 1, segment: 1))
        #expect(landed10 == " and then we shipped it.")
        let landed11 = land(&policy, &cursor, event(" So it works.", .final, 2, segment: 2))
        #expect(landed11 == " So it works.")
    }
}
