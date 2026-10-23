import Foundation

/// Conservative local shaping of dictated text, ported from Android's `FinalCasing` (#50). Pure: no editor, no
/// logging, no retained text. Only unmistakable cases change; anything unsure stays exactly as the server sent it.
public enum FinalCasing {
    static let openers = Set("([{<“‘«‹„‚¡¿")
    static let closingQuotes = Set("”’»›")
    static let followers = Set(",.;:!?…)]}\"”’'—–")
    static let breaks: Set<Character> = ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"]

    /// How much text before the dictation `midSentence` needs to see.
    public static let lookbehind = 16

    /// True when `before` (the text preceding the dictation) shows a sentence is already under way.
    public static func midSentence(_ before: String?) -> Bool {
        guard let before else { return false }
        var chars = Array(before)
        while let last = chars.last, last.isWhitespace {
            if breaks.contains(last) { return false }
            chars.removeLast()
        }
        while let last = chars.last {
            let previous = chars.count > 1 ? chars[chars.count - 2] : nil
            let closing = closingQuotes.contains(last) || ((last == "\"" || last == "'") && previous.map { !$0.isWhitespace && !openers.contains($0) } == true)
            guard closing else { break }
            chars.removeLast()
        }
        guard let last = chars.last else { return false } // field start, or only whitespace/quotes we cannot judge
        return last.isLetter || last.isNumber || last == "," || last == ";"
    }

    // Common sentence starters that are never names. Anything else capitalised may be a proper noun and stays.
    static let common = Set(("a about actually after again all also although an and another any anyone anything anyway anyways are " +
        "as at basically because before both but by can could did didn't do does doesn't don't each even every everyone " +
        "everything first for from got had has have he her here hey hi his honestly how however if in instead into is isn't it " +
        "it's its just let let's like maybe meanwhile more most much my never next no not nothing now of oh ok okay on once one only " +
        "or other otherwise our out over please plus probably really right same she should since so some someone something " +
        "sometimes still such sure than thanks that that's the their them then there there's these they they're they'll they've she's he's what's who's this those though " +
        "through to today tomorrow tonight too under unless until up us usually very want was wasn't we we'll we're we've well " +
        "went were what whatever when whenever where whether which while who why with without would wouldn't yeah yep yes yesterday " +
        "yet you you'll you're you've your").split(separator: " ").map(String.init))

    /// Lower-cases the first word when it is a known common word; "I", acronyms and mixed-case words never change.
    static func lowerFirstWord(_ text: String) -> String {
        let chars = Array(text)
        guard let start = chars.firstIndex(where: { !$0.isWhitespace }), chars[start].isLetter, chars[start].isUppercase else { return text }
        var end = start + 1
        while end < chars.count, chars[end].isLetter || ((chars[end] == "'" || chars[end] == "’") && end + 1 < chars.count && chars[end + 1].isLetter) {
            end += 1
        }
        let word = String(chars[start..<end])
        if end < chars.count, !chars[end].isWhitespace, !followers.contains(chars[end]) { return text } // A/B, A1, So-called
        if word.dropFirst().contains(where: \.isUppercase) { return text } // NASA, GitHub, McDonald
        let key = word.replacingOccurrences(of: "’", with: "'").lowercased()
        if key == "i" || key.hasPrefix("i'") || !common.contains(key) { return text }
        return String(chars[..<start]) + word.prefix(1).lowercased() + word.dropFirst() + String(chars[end...])
    }

    /// A trailing "new line" / "new paragraph" (the whole utterance or its tail, then only spaces and
    /// punctuation): the text before it, and the line breaks to type instead.
    static func command(in text: String) -> (head: String, breaks: String)? {
        for (phrase, breaks) in [("new paragraph", "\n\n"), ("new line", "\n")] {
            guard let range = text.range(of: phrase, options: [.backwards, .caseInsensitive]),
                  text[range.upperBound...].allSatisfy({ $0.isWhitespace || ".,!?…".contains($0) }),
                  range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)].isWhitespace else { continue }
            var head = String(text[..<range.lowerBound])
            while head.last?.isWhitespace == true { head.removeLast() }
            return (head, breaks)
        }
        return nil
    }

    /// Opt-in spoken `commands` first, then the mid-sentence first word.
    public static func shape(_ text: String, midSentence: Bool, commands: Bool) -> String {
        let found = commands ? command(in: text) : nil
        let head = found?.head ?? text
        return (midSentence ? lowerFirstWord(head) : head) + (found?.breaks ?? "")
    }
}
