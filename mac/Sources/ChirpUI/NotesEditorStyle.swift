import AppKit
import ChirpCore

/// Live Markdown styling for the notes editor: `NotesMarkdown.styleRuns` mapped to AppKit attributes. Attributes only;
/// the characters (and so the markup) never change.
@MainActor
enum NotesEditorStyle {
    static let bodySize: CGFloat = 14
    static let body = NSFont.systemFont(ofSize: bodySize)
    /// `[ ]` and `[x]` in a fixed-width face, so a toggle never shifts the text after it.
    static let box = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let gap = NSFont.systemFont(ofSize: 7)
    static let indentStep: CGFloat = 22
    static let lineSpacing: CGFloat = 3

    static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: NSFont.systemFont(ofSize: 22, weight: .bold)
        case 2: NSFont.systemFont(ofSize: 17, weight: .bold)
        default: NSFont.systemFont(ofSize: 15, weight: .semibold)
        }
    }

    static var baseParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        p.paragraphSpacing = 2
        return p
    }

    /// What new typing gets before the restyle catches up.
    static var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: baseParagraph]
    }

    private static var traitCache: [NSFont: [NSFontTraitMask.RawValue: NSFont]] = [:]

    private static func font(_ font: NSFont, adding trait: NSFontTraitMask) -> NSFont {
        if let cached = traitCache[font]?[trait.rawValue] { return cached }
        let converted = NSFontManager.shared.convert(font, toHaveTrait: trait)
        traitCache[font, default: [:]][trait.rawValue] = converted
        return converted
    }

    private static func width(_ s: String, _ font: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }

    /// Restyles the paragraphs `range` touches (the whole text when nil).
    static func restyle(_ storage: NSTextStorage, range: NSRange? = nil) {
        let ns = storage.string as NSString
        let target = range.map { ns.paragraphRange(for: NSRange(location: min($0.location, ns.length), length: max(0, min($0.length, ns.length - min($0.location, ns.length))))) }
            ?? NSRange(location: 0, length: ns.length)
        guard target.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes(typingAttributes, range: target)
        // A blank line between blocks is a half-height gap, not a full body line.
        var location = target.location
        while location < NSMaxRange(target) {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            if line.length == 1, ns.character(at: line.location) == 10 { storage.addAttribute(.font, value: gap, range: line) }
            location = NSMaxRange(line)
        }
        let runs = NotesMarkdown.styleRuns(Substring(ns.substring(with: target)), base: target.location)
        for run in runs { apply(run, to: storage, ns: ns) }
        storage.endEditing()
    }

    private static func apply(_ run: NotesStyleRun, to storage: NSTextStorage, ns: NSString) {
        let r = run.range
        guard r.length > 0, NSMaxRange(r) <= ns.length else { return }
        switch run.style {
        case .heading(let level):
            storage.addAttribute(.font, value: headingFont(level), range: r)
            let p = NSMutableParagraphStyle()
            p.lineSpacing = lineSpacing
            p.paragraphSpacingBefore = r.location == 0 ? 0 : (level == 1 ? 6 : level == 2 ? 4 : 2)
            p.paragraphSpacing = 3
            storage.addAttribute(.paragraphStyle, value: p, range: ns.paragraphRange(for: r))
        case .markupDelimiter:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
        case .bold, .italic:
            let trait: NSFontTraitMask = run.style == .bold ? .boldFontMask : .italicFontMask
            storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                guard let f = value as? NSFont else { return }
                storage.addAttribute(.font, value: font(f, adding: trait), range: sub)
            }
        case .bulletMarker(let indent):
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
            let line = ns.substring(with: ns.lineRange(for: r))
            let spaces = line.prefix { $0 == " " }.count
            // The leading spaces are kerned to exactly `indent` steps, so nesting reads the same however it was typed.
            if spaces > 0 {
                let kern = CGFloat(indent) * indentStep / CGFloat(spaces) - width(" ", body)
                storage.addAttribute(.kern, value: kern, range: NSRange(location: r.location, length: spaces))
            }
            let task = NotesMarkdown.listPrefix(Substring(line))?.box != nil
            let p = NSMutableParagraphStyle()
            p.lineSpacing = lineSpacing
            p.paragraphSpacing = 2
            p.headIndent = CGFloat(indent) * indentStep + width(String(line.dropFirst(spaces).prefix(2)), body)
                + (task ? width("[ ] ", box) : 0)
            storage.addAttribute(.paragraphStyle, value: p, range: ns.paragraphRange(for: r))
        case .taskBox:
            storage.addAttributes([.font: box, .foregroundColor: NSColor.secondaryLabelColor], range: r)
        case .checkedTaskText:
            storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                                   .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .strikethroughColor: NSColor.tertiaryLabelColor], range: r)
        case .decisionLabel:
            storage.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: r)
        case .questionLabel:
            storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: r)
        case .fallbackHeader:
            storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: font(body, adding: .italicFontMask)], range: r)
        }
    }
}
