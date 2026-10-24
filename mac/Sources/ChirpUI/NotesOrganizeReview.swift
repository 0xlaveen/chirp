import ChirpCore
import SwiftUI

/// Organize's changes block by block (a heading, a bullet, a paragraph): what stayed, what changed, what went and what
/// came, aligned before and after. The review sheet draws them with moon change bars instead of a red/green word diff.
public enum NotesBlockDiff {
    public enum Kind: Equatable, Sendable { case same, changed, removed, added }

    public struct Row: Equatable, Sendable, Identifiable {
        public var id: Int
        public var kind: Kind
        public var before: String?
        public var after: String?
    }

    /// The text's blocks: its non-blank lines, trimmed of trailing space.
    static func blocks(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) == "" ? "" : $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
    }

    /// Longest common subsequence of the blocks, then each run of removals next to a run of additions paired up as
    /// changes (the first with the first). Long documents fall back to comparing in place.
    public static func rows(before: String, after: String) -> [Row] {
        let a = blocks(before), b = blocks(after)
        var raw: [(Kind, String?, String?)] = []
        if a.count * b.count > 250_000 {
            for i in 0..<max(a.count, b.count) {
                let x = i < a.count ? a[i] : nil, y = i < b.count ? b[i] : nil
                raw.append((x == y ? .same : x == nil ? .added : y == nil ? .removed : .changed, x, y))
            }
        } else {
            var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
            var i = 0, j = 0
            var removed: [String] = [], added: [String] = []
            func flush() {
                let paired = min(removed.count, added.count)
                for k in 0..<paired { raw.append((.changed, removed[k], added[k])) }
                for r in removed.dropFirst(paired) { raw.append((.removed, r, nil)) }
                for n in added.dropFirst(paired) { raw.append((.added, nil, n)) }
                removed.removeAll()
                added.removeAll()
            }
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, a[i] == b[j] {
                    flush()
                    raw.append((.same, a[i], b[j]))
                    i += 1; j += 1
                } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                    added.append(b[j]); j += 1
                } else {
                    removed.append(a[i]); i += 1
                }
            }
            flush()
        }
        return raw.enumerated().map { Row(id: $0.offset, kind: $0.element.0, before: $0.element.1, after: $0.element.2) }
    }

    /// Unchanged runs longer than `context` on each side of a change fold into one "N unchanged" row (kind `.same`,
    /// both sides nil).
    public static func folded(_ rows: [Row], context: Int = 1) -> [Row] {
        let changed = rows.indices.filter { rows[$0].kind != .same }
        guard !changed.isEmpty else { return rows }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - context)...min(rows.count - 1, c + context) { keep.insert(k) } }
        var out: [Row] = []
        var hidden = 0
        for (i, row) in rows.enumerated() {
            if keep.contains(i) {
                if hidden > 0 { out.append(Row(id: -i, kind: .same, before: nil, after: "\(hidden)")); hidden = 0 }
                out.append(row)
            } else {
                hidden += 1
            }
        }
        if hidden > 0 { out.append(Row(id: -rows.count - 1, kind: .same, before: nil, after: "\(hidden)")) }
        return out
    }

    /// "3 changed · 1 removed · 2 added".
    public static func summary(_ rows: [Row]) -> String {
        let parts: [(Kind, String)] = [(.changed, "changed"), (.removed, "removed"), (.added, "added")]
        let text = parts.compactMap { kind, word in
            let n = rows.filter { $0.kind == kind && ($0.before != nil || $0.after != nil) }.count
            return n == 0 ? nil : "\(n) \(word)"
        }
        return text.isEmpty ? "No changes" : text.joined(separator: " · ")
    }
}

/// What Organize changed, block by block, with Restore previous and Keep. The same sheet opens from the chip's Show
/// changes and from Restore Notes Before Organize…, where the snapshots are listed by time.
struct OrganizeReviewSheet: View {
    @Bindable var model: NotesModel

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    var body: some View {
        let snapshot = model.reviewing.flatMap { model.snapshots.snapshot($0) }
        let rows = snapshot.map { NotesBlockDiff.rows(before: $0.before, after: $0.after) } ?? []
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "sparkles").foregroundStyle(Color.chirp.moon)
                Text("What Organize changed").font(ChirpType.noteTitle(20))
                Spacer()
                Text(NotesBlockDiff.summary(rows)).font(ChirpType.meta).foregroundStyle(NotesInk.secondary)
            }
            if model.snapshots.items.count > 1 {
                Picker("Before", selection: Binding(get: { model.reviewing ?? -1 }, set: { model.review($0) })) {
                    ForEach(model.snapshots.items.reversed()) { item in
                        Text("Before the change at \(Self.time.string(from: item.at))").tag(item.id)
                    }
                }
                .labelsHidden()
            }
            HStack(spacing: 0) {
                Text("Before").frame(maxWidth: .infinity, alignment: .leading)
                Text("After").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(NotesInk.secondary)
            .padding(.horizontal, 14)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(NotesBlockDiff.folded(rows)) { BlockRow(row: $0) }
                }
                .padding(8)
            }
            .frame(height: 300)
            .background(RoundedRectangle(cornerRadius: ChirpRadius.row).fill(Color.chirp.surface))
            .overlay(RoundedRectangle(cornerRadius: ChirpRadius.row).strokeBorder(NotesInk.tertiary.opacity(0.4)))
            if model.confirmingRestore != nil {
                Label("Notes you typed since sit among the changed lines. Restoring replaces the notes with the earlier text and loses them.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.chirp.moon)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Label("Changed blocks are marked in gold", systemImage: "rectangle.portrait.fill")
                    .labelStyle(GoldBarLabel())
                Spacer()
                if let id = model.reviewing {
                    if model.confirmingRestore == id {
                        Button("Replace notes (your later edits will be lost)", role: .destructive) { model.onRestoreSnapshot(id, true) }
                    } else {
                        Button("Restore previous") { model.onRestoreSnapshot(id, false) }
                            .disabled(!model.canRestore)
                    }
                }
                // Keeping is the common case: the prominent default. Esc keeps too (a zero-size twin carries the
                // cancel shortcut; one button cannot take both Return and Esc).
                Button("Keep") { model.closeReview() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Keep") { model.closeReview() }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .padding(20)
        .frame(width: 720)
        .background(Color.chirp.background)
        .tint(Color.chirp.koi)
    }
}

private struct GoldBarLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(Color.chirp.moonFill).frame(width: 3, height: 12)
            configuration.title.font(.caption).foregroundStyle(NotesInk.secondary)
        }
    }
}

/// One aligned row: before on the left, after on the right; a moon bar and tint mark what Organize touched.
private struct BlockRow: View {
    let row: NotesBlockDiff.Row

    var body: some View {
        if row.kind == .same, row.before == nil, let count = row.after {
            Text("⋯ \(count) unchanged")
                .font(.system(size: 11))
                .foregroundStyle(NotesInk.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
        } else {
            HStack(alignment: .top, spacing: 14) {
                cell(row.before, side: .before)
                cell(row.after, side: .after)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
        }
    }

    private enum Side { case before, after }

    private var label: String {
        switch row.kind {
        case .same: row.after ?? ""
        case .changed: "changed: \(row.before ?? "") to \(row.after ?? "")"
        case .removed: "removed: \(row.before ?? "")"
        case .added: "added: \(row.after ?? "")"
        }
    }

    @ViewBuilder private func cell(_ text: String?, side: Side) -> some View {
        let marked = row.kind != .same && text != nil
        HStack(alignment: .top, spacing: 8) {
            Capsule()
                .fill(marked ? Color.chirp.moonFill : .clear)
                .frame(width: 3)
            if let text {
                Text(NotesMarkdown.inline(BlockRow.plain(text)))
                    .font(.system(size: 12.5, weight: text.hasPrefix("#") ? .semibold : .regular))
                    .foregroundStyle(row.kind == .same ? NotesInk.secondary : NotesInk.primary)
                    .strikethrough(row.kind == .removed, color: NotesInk.tertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(side == .after ? "removed" : "new")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(NotesInk.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 5)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(marked ? Color.chirp.moonFill.opacity(0.16) : .clear))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A block's Markdown as reading text: heading marks dropped, bullets as •, task boxes as ☐ / ☑.
    static func plain(_ line: String) -> String {
        var s = line
        if let r = s.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"^\s*[-*+] \[[xX]\] "#, options: .regularExpression) { s.replaceSubrange(r, with: "☑ ") }
        if let r = s.range(of: #"^\s*[-*+] \[ \] "#, options: .regularExpression) { s.replaceSubrange(r, with: "☐ ") }
        if let r = s.range(of: #"^\s*[-*+] "#, options: .regularExpression) { s.replaceSubrange(r, with: "• ") }
        return s
    }
}
