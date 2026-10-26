import UIKit
import KeyboardKit
import KeyboardPolicy

/// Suggestions from the on-device spell checker (`UITextChecker`) and the user's lexicon (`UILexicon`: text
/// replacements and contact names); the choices are `Typing`'s. Nothing leaves the device: learned words live in
/// `UITextChecker`'s per-app store, ignored words only in memory.
///
/// KeyboardKit calls `autocomplete(_:)` off the main actor; the checker runs on the main actor and only the
/// Sendable policy result crosses back.
public final class ChirpAutocompleteService: AutocompleteService, @unchecked Sendable {
    public var locale: Locale = Locale(identifier: "en_US")
    /// Text replacements and contact names, refreshed by the controller from `requestSupplementaryLexicon`.
    @MainActor public var lexicon: [LexiconEntry] = []
    /// Whether the host field allows autocorrect at all (`autocorrectionType`, keyboard type).
    @MainActor public var allowsAutocorrect = true
    @MainActor private lazy var checker = UITextChecker()
    @MainActor private var ignored: Set<String> = []

    public init() {}

    public func autocomplete(_ text: String) async throws -> Autocomplete.ServiceResult {
        let suggestions = await MainActor.run { self.suggestions(before: text) }
        return Autocomplete.ServiceResult(inputText: text, suggestions: suggestions.map(Self.suggestion))
    }

    /// The suggestion bar for the text before the caret.
    @MainActor public func suggestions(before text: String) -> [TypingSuggestion] {
        let word = Typing.currentWord(before: text)
        guard allowsAutocorrect, !word.isEmpty else { return [] }
        return Typing.suggestions(for: word, report: report(for: word), lexicon: lexicon,
                                  protected: isProtected(word), autocorrect: true)
    }

    @MainActor private func report(for word: String) -> SpellReport {
        let language = Self.language(for: locale)
        let range = NSRange(location: 0, length: (word as NSString).length)
        let miss = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language)
        let misspelled = miss.location != NSNotFound
        return SpellReport(misspelled: misspelled,
                           guesses: misspelled ? checker.guesses(forWordRange: range, in: word, language: language) ?? [] : [],
                           completions: checker.completions(forPartialWordRange: range, in: word, language: language) ?? [])
    }

    @MainActor private func isProtected(_ word: String) -> Bool {
        UITextChecker.hasLearnedWord(word) || ignored.contains(word.lowercased())
            || lexicon.contains { $0.output.caseInsensitiveCompare(word) == .orderedSame }
    }

    static func language(for locale: Locale) -> String {
        let available = UITextChecker.availableLanguages
        let wanted = locale.identifier.replacingOccurrences(of: "-", with: "_")
        if available.contains(wanted) { return wanted }
        let prefix = locale.language.languageCode?.identifier ?? "en"
        return available.first { $0.hasPrefix(prefix) } ?? "en_US"
    }

    static func suggestion(_ s: TypingSuggestion) -> Autocomplete.Suggestion {
        switch s.kind {
        case .verbatim: Autocomplete.Suggestion(text: s.text, type: .unknown, title: "“\(s.text)”")
        case .autocorrect: Autocomplete.Suggestion(text: s.text, type: .autocorrect)
        case .regular: Autocomplete.Suggestion(text: s.text)
        }
    }

    // MARK: Learning (on device only)

    public var canIgnoreWords: Bool { true }
    public var canLearnWords: Bool { true }
    public var ignoredWords: [String] { MainActor.assumeIsolated { Array(ignored) } }
    public var learnedWords: [String] { [] }
    public func hasIgnoredWord(_ word: String) -> Bool { MainActor.assumeIsolated { ignored.contains(word.lowercased()) } }
    public func hasLearnedWord(_ word: String) -> Bool { MainActor.assumeIsolated { UITextChecker.hasLearnedWord(word) } }
    public func ignoreWord(_ word: String) { MainActor.assumeIsolated { _ = ignored.insert(word.lowercased()) } }
    public func learnWord(_ word: String) { MainActor.assumeIsolated { UITextChecker.learnWord(word) } }
    public func removeIgnoredWord(_ word: String) { MainActor.assumeIsolated { _ = ignored.remove(word.lowercased()) } }
    public func unlearnWord(_ word: String) { MainActor.assumeIsolated { UITextChecker.unlearnWord(word) } }
}
