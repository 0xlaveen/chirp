import ChirpIOSCore
import SwiftUI

/// Reading-first Markdown. Task actions edit the original line, keeping the recorder's edit protection intact.
struct NotesBlocksView: View {
    let text: String
    var toggleTask: ((Int) -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                row(line, index: index)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).lineSpacing(5)
    }

    @ViewBuilder private func row(_ line: String, index: Int) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let candidate = (trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed)
            .replacingOccurrences(of: "**", with: "")
        let callout = candidate.lowercased().hasPrefix("decision:") || candidate.lowercased().hasPrefix("question:")
        if trimmed == "---" { Divider().padding(.vertical, 8) }
        else if trimmed.hasPrefix("#") {
            let level = trimmed.prefix(while: { $0 == "#" }).count
            inline(String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces))
                .font(level == 1 ? ChirpType.noteTitle : level == 2 ? ChirpType.h2 : .headline)
                .padding(.top, level < 3 ? 12 : 4).accessibilityAddTraits(.isHeader)
        } else if trimmed.range(of: #"^[-*+] \[[ xX]\] "#, options: .regularExpression) != nil {
            let checked = !trimmed.hasPrefix(String(trimmed.prefix(2)) + "[ ]")
            Toggle(isOn: Binding(get: { checked }, set: { _ in toggleTask?(index) })) {
                inline(String(trimmed.dropFirst(6))).strikethrough(checked).foregroundStyle(checked ? Color.chirp.inkMuted : .primary)
            }.toggleStyle(NoteTaskStyle()).padding(.leading, line.hasPrefix("  ") ? 20 : 0)
        } else if trimmed.hasPrefix(">") || callout {
            let value = trimmed.hasPrefix(">") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : candidate
            let decision = value.localizedCaseInsensitiveContains("decision")
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(decision ? Color.chirp.lily : .chirp.moon).frame(width: 3)
                inline(value).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }.fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12)
                .background((decision ? Color.chirp.lily : .chirp.moonFill).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•").foregroundStyle(Color.chirp.inkMuted)
                inline(String(trimmed.dropFirst(2)))
            }.padding(.leading, line.hasPrefix("  ") ? 20 : 0)
        } else if trimmed.isEmpty { Color.clear.frame(height: 4).accessibilityHidden(true) }
        else { inline(trimmed) }
    }

    private func inline(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
}

private struct NoteTaskStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.chirp.lily : .chirp.inkMuted)
                configuration.label
            }.frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(configuration.isOn ? "Checked" : "Unchecked")
    }
}
