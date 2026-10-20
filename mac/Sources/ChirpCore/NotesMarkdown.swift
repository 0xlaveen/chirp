import Foundation

/// One line of notes, in the small Markdown subset the server's guards allow.
public enum NotesMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// `- text`, `  - text` (indent 1), `    - text` (indent 2), `- [ ] text` (task) and `- [x] text` (checked).
    case bullet(indent: Int, text: String, task: Bool, checked: Bool)
    case paragraph(String)
    /// `_(nothing yet)_`: the window had nothing substantive.
    case placeholder
}

/// A styled stretch of the notes source, UTF-16 offsets. Styling never changes characters: the editor maps each run to
/// attributes, and the markup stays visible.
public struct NotesStyleRun: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// The whole heading line, `#`…`###` (level 1…3).
        case heading(Int)
        /// `#`/`##`/`###` markers, `**`, `_` and `*` around emphasis: drawn faint.
        case markupDelimiter
        case bold
        case italic
        /// A list line's leading spaces and `- ` / `* ` marker; `indent` is the nesting level (0…2).
        case bulletMarker(indent: Int)
        /// `[ ]` or `[x]`.
        case taskBox(checked: Bool)
        /// The text after `[x] `.
        case checkedTaskText
        /// `Decision:` in `- **Decision:** …`.
        case decisionLabel
        /// `Question:` in `- **Question:** …`.
        case questionLabel
        /// `_Not structured — see transcript_`.
        case fallbackHeader
    }

    public var range: NSRange
    public var style: Style

    public init(_ range: NSRange, _ style: Style) {
        self.range = range
        self.style = style
    }
}

/// Parses the notes subset line by line. Anything it does not recognise is a paragraph, so a stray table or HTML line
/// is shown as plain text and never interpreted. No third-party Markdown.
public enum NotesMarkdown {
    public static let placeholder = "_(nothing yet)_"
    /// List nesting the editor and Preview indent (0, 1 and 2).
    public static let maxIndent = 2

    public static func blocks(_ md: String) -> [NotesMarkdownBlock] {
        md.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { block(String($0)) }
    }

    static func block(_ raw: String) -> NotesMarkdownBlock? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        if line == placeholder { return .placeholder }
        if let (level, text) = heading(line) { return .heading(level: level, text: text) }
        if let list = listPrefix(Substring(raw)) {
            let text = raw.dropFirst(list.length).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return .bullet(indent: list.indent, text: text, task: list.box != nil, checked: list.box == true) }
        }
        return .paragraph(line)
    }

    /// `# `, `## ` or `### ` followed by text.
    static func heading(_ line: some StringProtocol) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (hashes, text)
    }

    /// A list line's prefix: leading spaces, `- ` or `* `, and an optional `[ ] `/`[x] ` box (`box` is its checked
    /// state). `length` counts UTF-16 units, all ASCII, through the box's trailing space.
    public static func listPrefix(_ line: Substring) -> (spaces: Int, indent: Int, box: Bool?, length: Int)? {
        let spaces = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(spaces)
        guard let m = rest.first, m == "-" || m == "*", rest.dropFirst().first == " " else { return nil }
        let indent = min(spaces / 2, maxIndent)
        let afterMarker = rest.dropFirst(2)
        for (box, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where afterMarker.hasPrefix(box) {
            return (spaces, indent, checked, spaces + 2 + 4)
        }
        // A box at the very end of the line (`- [ ]` while typing) still reads as a task.
        for (box, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] where afterMarker == Substring(box) {
            return (spaces, indent, checked, spaces + 2 + 3)
        }
        return (spaces, indent, nil, spaces + 2)
    }

    /// The headings (levels 1–3) of `md`, in order.
    public static func headings(_ md: String) -> [String] {
        blocks(md).compactMap { if case .heading(_, let text) = $0 { text } else { nil } }
    }

    /// Inline styling (`**bold**`, `_italic_`) for display, with links shown as their text only. Plain text when the
    /// line does not parse.
    public static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var styled = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in styled.runs where run.link != nil { styled[run.range].link = nil }
        return styled
    }

    // MARK: live styling

    /// The style runs of `text`, offset by `base` (the UTF-16 location of `text` in the whole document). Pure: the
    /// editor restyles only the paragraphs an edit touched and passes each with its location.
    public static func styleRuns(_ text: Substring, base: Int = 0) -> [NotesStyleRun] {
        var runs: [NotesStyleRun] = []
        var location = base
        for line in lines(text) {
            lineRuns(line, at: location, into: &runs)
            location += line.utf16.count + 1
        }
        return runs
    }

    /// Lines split on UTF-16 `\n` (Swift's `"\n"` Character does not match the `"\r\n"` grapheme), so offsets
    /// stay exact for CRLF text too; a line keeps its `\r`.
    static func lines(_ text: Substring) -> [Substring] {
        text.utf16.split(separator: 10, omittingEmptySubsequences: false).map { Substring($0) }
    }

    private static func lineRuns(_ line: Substring, at start: Int, into runs: inout [NotesStyleRun]) {
        let length = line.utf16.count
        guard length > 0 else { return }
        func range(_ from: Int, _ count: Int) -> NSRange { NSRange(location: start + from, length: count) }
        if line == Substring(NotesDocument.fallbackHeader) {
            runs.append(NotesStyleRun(range(0, length), .fallbackHeader))
            runs.append(NotesStyleRun(range(0, 1), .markupDelimiter))
            runs.append(NotesStyleRun(range(length - 1, 1), .markupDelimiter))
            return
        }
        if let (level, _) = heading(line) {
            runs.append(NotesStyleRun(range(0, length), .heading(level)))
            runs.append(NotesStyleRun(range(0, level), .markupDelimiter))
            inlineRuns(line.dropFirst(level + 1), at: start + level + 1, into: &runs)
            return
        }
        guard let list = listPrefix(line) else {
            inlineRuns(line, at: start, into: &runs)
            return
        }
        runs.append(NotesStyleRun(range(0, list.spaces + 2), .bulletMarker(indent: list.indent)))
        var body = list.spaces + 2
        if let checked = list.box {
            runs.append(NotesStyleRun(range(body, 3), .taskBox(checked: checked)))
            body = list.length
            if checked, body < length { runs.append(NotesStyleRun(range(body, length - body), .checkedTaskText)) }
        }
        let text = line.dropFirst(body)
        inlineRuns(text, at: start + body, into: &runs)
        for (label, style) in [("**Decision:**", NotesStyleRun.Style.decisionLabel), ("**Question:**", .questionLabel)]
        where list.box == nil && text.hasPrefix(label) {
            runs.append(NotesStyleRun(range(body + 2, label.utf16.count - 4), style))
        }
    }

    /// `**bold**`, then `_italic_` / `*italic*` outside the bold spans. The delimiters are separate runs.
    private static func inlineRuns(_ text: Substring, at start: Int, into runs: inout [NotesStyleRun]) {
        let units = Array(text.utf16)
        let star = UInt16(UInt8(ascii: "*")), under = UInt16(UInt8(ascii: "_")), space = UInt16(UInt8(ascii: " "))
        var bold: [Range<Int>] = []
        var i = 0
        // Bold: `**` + non-space … non-space + `**`.
        while i + 1 < units.count {
            if units[i] == star, units[i + 1] == star, i + 2 < units.count, units[i + 2] != space, units[i + 2] != star {
                var j = i + 3
                var close: Int?
                while j + 1 < units.count {
                    if units[j] == star, units[j + 1] == star, units[j - 1] != space { close = j; break }
                    j += 1
                }
                if let close {
                    runs.append(NotesStyleRun(NSRange(location: start + i, length: close + 2 - i), .bold))
                    runs.append(NotesStyleRun(NSRange(location: start + i, length: 2), .markupDelimiter))
                    runs.append(NotesStyleRun(NSRange(location: start + close, length: 2), .markupDelimiter))
                    bold.append(i..<(close + 2))
                    i = close + 2
                    continue
                }
            }
            i += 1
        }
        func isWord(_ u: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(u) else { return true }   // a surrogate half: part of a word
            return CharacterSet.alphanumerics.contains(scalar)
        }
        func inBold(_ k: Int) -> Bool { bold.contains { $0.contains(k) } }
        // Italic: a lone `_` or `*` not inside a word, opening before a non-space and closing after one.
        i = 0
        while i < units.count {
            let d = units[i]
            guard d == under || d == star, !inBold(i), i + 1 < units.count, units[i + 1] != space, units[i + 1] != d,
                  i == 0 || (!isWord(units[i - 1]) && units[i - 1] != d) else { i += 1; continue }
            var j = i + 2
            var close: Int?
            while j < units.count {
                if inBold(j) { break }
                if units[j] == d, units[j - 1] != space, j + 1 == units.count || (!isWord(units[j + 1]) && units[j + 1] != d) {
                    close = j
                    break
                }
                j += 1
            }
            if let close {
                runs.append(NotesStyleRun(NSRange(location: start + i, length: close + 1 - i), .italic))
                runs.append(NotesStyleRun(NSRange(location: start + i, length: 1), .markupDelimiter))
                runs.append(NotesStyleRun(NSRange(location: start + close, length: 1), .markupDelimiter))
                i = close + 1
            } else {
                i += 1
            }
        }
    }

    // MARK: structure

    /// The document's sections: one starts at each line matching `^#{1,3} \S`; text before the first heading is
    /// section 0 (heading nil). Every UTF-16 unit belongs to exactly one section, trailing newlines included.
    public static func sections(_ text: String) -> [(range: NSRange, heading: String?)] {
        var result: [(range: NSRange, heading: String?)] = []
        var start = 0, location = 0
        var current: String?
        for line in lines(Substring(text)) {
            if let (_, title) = heading(line) {
                if location > start || current != nil { result.append((NSRange(location: start, length: location - start), current)) }
                start = location
                current = title
            }
            location += line.utf16.count + 1
        }
        let end = text.utf16.count
        if end > start || current != nil { result.append((NSRange(location: start, length: end - start), current)) }
        return result
    }

    /// Clicking `[ ]`/`[x]` at UTF-16 offset `index`: the box's inner character and its replacement, or nil when
    /// `index` is not on a task box.
    public static func taskToggle(_ text: String, at index: Int) -> (range: NSRange, replacement: String)? {
        let ns = text as NSString
        guard index >= 0, index <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: min(index, max(0, ns.length - 1)), length: 0))
        let line = Substring(ns.substring(with: lineRange).trimmingCharacters(in: .newlines))
        guard let list = listPrefix(line), let checked = list.box else { return nil }
        let box = lineRange.location + list.spaces + 2
        guard (box...(box + 3)).contains(index) else { return nil }
        return (NSRange(location: box + 1, length: 1), checked ? " " : "x")
    }
}
