import Foundation

/// The key layout the typing keyboard opens with for a host field, from its `UIKeyboardType`. Raw values keep this
/// package free of UIKit; `KeyboardTyping` maps the result onto KeyboardKit's keyboard types.
public enum TypingLayout: String, Sendable, Equatable, CaseIterable {
    /// QWERTY letters.
    case letters
    /// The 123 page (digits and punctuation), with ABC to go back.
    case numbers
    /// The digit pad (one-time codes, PINs).
    case numberPad
    /// Letters with `@` and `.` beside a narrower space bar.
    case email
    /// Letters with `.`, `/` and `.com` instead of a space bar.
    case url
    /// Letters with a space bar and `.`.
    case webSearch

    /// `UIKeyboardType` raw values: default 0, asciiCapable 1, numbersAndPunctuation 2, URL 3, numberPad 4,
    /// phonePad 5, namePhonePad 6, emailAddress 7, decimalPad 8, twitter 9, webSearch 10, asciiCapableNumberPad 11.
    /// Phone and decimal pads open on the 123 page: KeyboardKit's digit pad has no `+`, `*`, `#` or decimal point.
    public init(keyboardTypeRawValue raw: Int) {
        switch raw {
        case 2, 5, 8: self = .numbers
        case 3: self = .url
        case 4, 11: self = .numberPad
        case 7: self = .email
        case 10: self = .webSearch
        default: self = .letters
        }
    }

    /// Fields where a word is not prose: no autocorrect and no suggestions (an address or a code is never "fixed").
    public var allowsAutocorrect: Bool { self == .letters || self == .webSearch }
}

public extension ReturnKey {
    /// From a `UIReturnKeyType` raw value: default 0, go 1, google 2, join 3, next 4, route 5, search 6, send 7,
    /// yahoo 8, done 9, emergencyCall 10, continue 11.
    init(returnKeyTypeRawValue raw: Int) {
        switch raw {
        case 0: self = .plain
        case 1: self = .go
        case 2, 6, 8: self = .search
        case 3: self = .join
        case 4, 10: self = .next
        case 5: self = .route
        case 7: self = .send
        case 9: self = .done
        case 11: self = .continue
        default: self = .other
        }
    }

}

/// One entry of the suggestion bar.
public struct TypingSuggestion: Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        /// What was typed, shown in quotes when a correction is offered; tapping keeps it (and learns it).
        case verbatim
        /// Replaces the word when Space is pressed (a spelling fix or a text replacement shortcut).
        case autocorrect
        /// A completion, a contact name or a spelling alternative.
        case regular
    }
    public var text: String
    public var kind: Kind
    public init(text: String, kind: Kind) { self.text = text; self.kind = kind }
}

/// Text replacement shortcuts and contact names from `UILexicon`, mirrored as plain strings.
public struct LexiconEntry: Equatable, Sendable {
    /// What the user types ("omw").
    public var input: String
    /// What it becomes ("On my way!"). For a contact name both are the name.
    public var output: String
    public init(input: String, output: String) { self.input = input; self.output = output }
    public var isShortcut: Bool { input.caseInsensitiveCompare(output) != .orderedSame }
}

/// What the spell checker said about the word being typed.
public struct SpellReport: Equatable, Sendable {
    public var misspelled: Bool
    public var guesses: [String]
    public var completions: [String]
    public init(misspelled: Bool, guesses: [String] = [], completions: [String] = []) {
        self.misspelled = misspelled; self.guesses = guesses; self.completions = completions
    }
}

/// Suggestions and autocorrect for the word before the caret. Deliberately conservative: a word is only replaced
/// on Space when the checker calls it misspelled, it looks like prose (letters and apostrophes, no acronym or
/// camelCase), the user never kept it, and the best guess is a close edit. Everything else is only offered.
public enum Typing {
    public static let suggestionLimit = 3

    /// The word fragment directly before the caret (letters, digits and apostrophes), or "" after a space or
    /// punctuation.
    public static func currentWord(before text: String?) -> String {
        guard let text else { return "" }
        var word = ""
        for character in text.reversed() {
            guard character.isLetter || character.isNumber || character == "'" || character == "’" else { break }
            word.insert(character, at: word.startIndex)
        }
        return word
    }

    /// Whether `word` may be replaced at all: prose only, never a code, a handle, an acronym or a learned word.
    public static func isCorrectable(_ word: String, protected: Bool) -> Bool {
        guard !protected, word.count >= 2, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return false }
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        if letters.count > 1, letters == letters.uppercased() { return false }  // NASA, OK
        let tail = letters.dropFirst()
        if tail.contains(where: \.isUppercase) { return false }                 // iPhone, McDonald
        return true
    }

    /// The autocorrection for `word`, or nil. The guess keeps the word's leading capital.
    public static func correction(for word: String, report: SpellReport, protected: Bool) -> String? {
        if word == "i" { return "I" }
        guard report.misspelled, isCorrectable(word, protected: protected), let guess = report.guesses.first else { return nil }
        let limit = word.count <= 4 ? 1 : 2
        guard editDistance(normalized(word), normalized(guess)) <= limit else { return nil }
        return matchCase(guess, to: word)
    }

    /// The suggestion bar for the current word: at most three, no duplicates, the autocorrection in the middle with
    /// the typed word in quotes before it (as on Apple's keyboard).
    public static func suggestions(for word: String, report: SpellReport, lexicon: [LexiconEntry],
                                   protected: Bool, autocorrect: Bool) -> [TypingSuggestion] {
        guard !word.isEmpty else { return [] }
        let shortcut = lexicon.first { $0.isShortcut && $0.input.caseInsensitiveCompare(word) == .orderedSame }
        let fix = shortcut?.output ?? correction(for: word, report: report, protected: protected)
        var result: [TypingSuggestion] = []
        func add(_ text: String, _ kind: TypingSuggestion.Kind) {
            guard result.count < suggestionLimit, !text.isEmpty,
                  !result.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else { return }
            result.append(TypingSuggestion(text: text, kind: kind))
        }
        if let fix, fix != word {
            add(word, .verbatim)
            add(fix, autocorrect ? .autocorrect : .regular)
        } else {
            add(word, .verbatim)
        }
        let names = lexicon.filter { !$0.isShortcut && $0.output.count > word.count
            && $0.output.lowercased().hasPrefix(word.lowercased()) }.map(\.output)
        let alternatives = report.misspelled ? report.guesses : report.completions
        for text in names + alternatives.map({ matchCase($0, to: word) }) { add(text, .regular) }
        return result
    }

    /// Apple-style revert: Delete right after an autocorrection (the corrected word and the one space after it)
    /// puts back exactly what was typed. Returns the characters to delete and the text to insert.
    public static func revert(_ memory: AutocorrectMemory?, before text: String?) -> (delete: Int, insert: String)? {
        guard let memory, let text, text.hasSuffix(memory.corrected + " ") else { return nil }
        let start = text.dropLast(memory.corrected.count + 1)
        // The correction must start a word, or it was not ours.
        if let last = start.last, last.isLetter || last.isNumber { return nil }
        return (memory.corrected.count + 1, memory.original)
    }

    static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0 != "'" && $0 != "’" }
    }

    static func matchCase(_ text: String, to word: String) -> String {
        guard let first = word.first, first.isUppercase, let head = text.first else { return text }
        return head.uppercased() + text.dropFirst()
    }

    /// Optimal string alignment distance (Damerau-Levenshtein with adjacent transpositions).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }
}

/// The last autocorrection, kept only until the next key so Delete can revert it.
public struct AutocorrectMemory: Equatable, Sendable {
    public var original: String
    public var corrected: String
    public init(original: String, corrected: String) { self.original = original; self.corrected = corrected }
}
