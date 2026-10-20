import Foundation

/// One line of structured notes, in the small Markdown subset the server's guards allow.
public enum NotesMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// `- text`, `  - text` (indent 1) and `- [ ] text` (task).
    case bullet(indent: Int, text: String, task: Bool)
    case paragraph(String)
    /// `_(nothing yet)_`: the window had nothing substantive.
    case placeholder
}

/// Parses the notes subset line by line. Anything it does not recognise is a paragraph, so a stray H1, table or HTML
/// line is shown as plain text and never interpreted. No third-party Markdown.
public enum NotesMarkdown {
    public static let placeholder = "_(nothing yet)_"

    public static func blocks(_ md: String) -> [NotesMarkdownBlock] {
        md.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { block(String($0)) }
    }

    static func block(_ raw: String) -> NotesMarkdownBlock? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        if line == placeholder { return .placeholder }
        for level in [3, 2] {
            let marker = String(repeating: "#", count: level) + " "
            if line.hasPrefix(marker) {
                let text = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return .heading(level: level, text: text) }
            }
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            let leading = raw.prefix { $0 == " " || $0 == "\t" }
            let indent = leading.isEmpty ? 0 : 1
            var text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            var task = false
            for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
                task = true
                text = String(text.dropFirst(box.count)).trimmingCharacters(in: .whitespaces)
            }
            if !text.isEmpty { return .bullet(indent: indent, text: text, task: task) }
        }
        return .paragraph(line)
    }

    /// The `##`/`###` headings of `md`, in order.
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
}
