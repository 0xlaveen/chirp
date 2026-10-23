import Foundation

/// Long sessions: where each section was said (the Preview's `[hh:mm:ss]` jump) and how far the notes are behind.
extension NotesDocument {
    /// A heading as a lookup key: case, emphasis markers and spacing aside.
    public static func headingKey(_ heading: String) -> String {
        heading.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "_", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// A pass's Markdown for the open window: headings it introduces are stamped with the first segment
    /// it covered that no earlier pass did (a heading already stamped keeps its time). Call before `structuredEnd` moves.
    mutating func stampSections(_ markdown: String) {
        let firstNew = max(windowStart, structuredEnd + 1)
        guard firstNew < segments.count,
              let offset = segments[firstNew...].first(where: { !$0.isGap && !$0.text.isEmpty })?.offset ?? windowSegments.first?.offset
        else { return }
        for heading in NotesMarkdown.headings(markdown) where sectionOffsets[Self.headingKey(heading)] == nil {
            sectionOffsets[Self.headingKey(heading)] = offset
        }
    }

    /// When the section under `heading` was first said, if it came from speech.
    public func sectionOffset(_ heading: String) -> TimeInterval? { sectionOffsets[Self.headingKey(heading)] }

    /// Seconds of committed speech no pass has structured yet (the lag chip): each waiting segment's audio.
    public var unstructuredSeconds: TimeInterval {
        windowSegments.filter { $0.id > structuredEnd }.reduce(0) { $0 + max(0, ($1.end ?? $1.offset) - $1.offset) }
    }
}
