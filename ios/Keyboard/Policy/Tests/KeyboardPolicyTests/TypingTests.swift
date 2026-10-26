import Testing
@testable import KeyboardPolicy

@Suite struct KeyboardTypeMappingTests {
    @Test func everyUIKeyboardTypeHasALayout() {
        let expected: [Int: TypingLayout] = [0: .letters, 1: .letters, 2: .numbers, 3: .url, 4: .numberPad, 5: .numbers,
                                             6: .letters, 7: .email, 8: .numbers, 9: .letters, 10: .webSearch, 11: .numberPad]
        for (raw, layout) in expected { #expect(TypingLayout(keyboardTypeRawValue: raw) == layout, "UIKeyboardType \(raw)") }
        #expect(TypingLayout(keyboardTypeRawValue: 99) == .letters, "an unknown future type still types")
    }

    @Test func addressesAndCodesAreNeverAutocorrected() {
        #expect(TypingLayout.letters.allowsAutocorrect && TypingLayout.webSearch.allowsAutocorrect)
        for layout in [TypingLayout.email, .url, .numbers, .numberPad] { #expect(!layout.allowsAutocorrect, "\(layout)") }
    }
}

@Suite struct ReturnKeyMappingTests {
    @Test func everyUIReturnKeyTypeMaps() {
        let expected: [Int: ReturnKey] = [0: .plain, 1: .go, 2: .search, 3: .join, 4: .next, 5: .route, 6: .search,
                                          7: .send, 8: .search, 9: .done, 10: .next, 11: .continue]
        for (raw, key) in expected { #expect(ReturnKey(returnKeyTypeRawValue: raw) == key, "UIReturnKeyType \(raw)") }
        #expect(ReturnKey(returnKeyTypeRawValue: 42) == .other)
    }
}

@Suite struct AutocorrectTests {
    let teh = SpellReport(misspelled: true, guesses: ["the", "tech"])

    @Test func currentWordStopsAtSpacesAndPunctuation() {
        #expect(Typing.currentWord(before: "Hello wor") == "wor")
        #expect(Typing.currentWord(before: "Hello ") == "")
        #expect(Typing.currentWord(before: "(don't") == "don't")
        #expect(Typing.currentWord(before: nil) == "")
        #expect(Typing.currentWord(before: "e-mail") == "mail")
    }

    @Test func correctsCloseMisspellingsKeepingTheCapital() {
        #expect(Typing.correction(for: "teh", report: teh, protected: false) == "the")
        #expect(Typing.correction(for: "Teh", report: teh, protected: false) == "The")
        #expect(Typing.correction(for: "recieve", report: SpellReport(misspelled: true, guesses: ["receive"]), protected: false) == "receive")
        #expect(Typing.correction(for: "dont", report: SpellReport(misspelled: true, guesses: ["don't"]), protected: false) == "don't")
        #expect(Typing.correction(for: "i", report: SpellReport(misspelled: false), protected: false) == "I")
    }

    @Test func conservative() {
        #expect(Typing.correction(for: "the", report: SpellReport(misspelled: false, guesses: ["then"]), protected: false) == nil,
                "a correctly spelled word is never replaced")
        #expect(Typing.correction(for: "teh", report: teh, protected: true) == nil, "learned, ignored or a contact")
        #expect(Typing.correction(for: "NASA", report: SpellReport(misspelled: true, guesses: ["NASAL"]), protected: false) == nil)
        #expect(Typing.correction(for: "iPhone", report: SpellReport(misspelled: true, guesses: ["phone"]), protected: false) == nil)
        #expect(Typing.correction(for: "abc123", report: SpellReport(misspelled: true, guesses: ["abc"]), protected: false) == nil)
        #expect(Typing.correction(for: "xq", report: SpellReport(misspelled: true, guesses: ["quixotic"]), protected: false) == nil,
                "a distant guess is offered, not forced")
        #expect(Typing.correction(for: "zorb", report: SpellReport(misspelled: true, guesses: ["herb"]), protected: false) == nil,
                "short words allow only one edit")
        #expect(Typing.correction(for: "teh", report: SpellReport(misspelled: true), protected: false) == nil)
    }

    @Test func suggestionBarPutsTheFixAfterTheTypedWord() {
        let bar = Typing.suggestions(for: "teh", report: teh, lexicon: [], protected: false, autocorrect: true)
        #expect(bar == [TypingSuggestion(text: "teh", kind: .verbatim), TypingSuggestion(text: "the", kind: .autocorrect),
                        TypingSuggestion(text: "tech", kind: .regular)])
        let off = Typing.suggestions(for: "teh", report: teh, lexicon: [], protected: false, autocorrect: false)
        #expect(off.map(\.kind) == [.verbatim, .regular, .regular], "autocorrect off still offers the fix")
    }

    @Test func completionsWhileTypingAKnownPrefix() {
        let report = SpellReport(misspelled: false, completions: ["hello", "help", "hellish", "helmet"])
        let bar = Typing.suggestions(for: "Hel", report: report, lexicon: [], protected: false, autocorrect: true)
        #expect(bar.map(\.text) == ["Hel", "Hello", "Help"] && bar.count == Typing.suggestionLimit)
        #expect(!bar.contains { $0.kind == .autocorrect })
        #expect(Typing.suggestions(for: "", report: report, lexicon: [], protected: false, autocorrect: true).isEmpty)
    }

    @Test func lexiconShortcutsAndContactNames() {
        let lexicon = [LexiconEntry(input: "omw", output: "On my way!"), LexiconEntry(input: "Avery", output: "Avery")]
        let shortcut = Typing.suggestions(for: "omw", report: SpellReport(misspelled: true, guesses: ["mow"]), lexicon: lexicon,
                                          protected: false, autocorrect: true)
        #expect(shortcut.prefix(2) == [TypingSuggestion(text: "omw", kind: .verbatim), TypingSuggestion(text: "On my way!", kind: .autocorrect)])
        let name = Typing.suggestions(for: "av", report: SpellReport(misspelled: false, completions: ["available"]), lexicon: lexicon,
                                      protected: false, autocorrect: true)
        #expect(name.map(\.text) == ["av", "Avery", "available"])
    }

    @Test func noDuplicatesIgnoringCase() {
        let bar = Typing.suggestions(for: "the", report: SpellReport(misspelled: false, completions: ["the", "The", "then"]),
                                     lexicon: [], protected: false, autocorrect: true)
        #expect(bar.map(\.text) == ["the", "then"])
    }

    @Test func deleteRightAfterAnAutocorrectionPutsBackTheTypedWord() {
        let memory = AutocorrectMemory(original: "teh", corrected: "the")
        #expect(Typing.revert(memory, before: "I saw the ")! == (4, "teh"))
        #expect(Typing.revert(memory, before: "the ")! == (4, "teh"))
        #expect(Typing.revert(memory, before: "I saw the  ") == nil, "a second space means the user moved on")
        #expect(Typing.revert(memory, before: "I saw the") == nil)
        #expect(Typing.revert(memory, before: "bathe ") == nil, "only a whole word we corrected")
        #expect(Typing.revert(nil, before: "the ") == nil)
    }

    @Test func editDistanceCountsTranspositionsOnce() {
        #expect(Typing.editDistance("teh", "the") == 1)
        #expect(Typing.editDistance("kitten", "sitting") == 3)
        #expect(Typing.editDistance("", "abc") == 3)
    }
}
