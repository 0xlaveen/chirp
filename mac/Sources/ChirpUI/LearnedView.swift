import AppKit
import ChirpCore
import Observation
import SwiftUI

/// The words of Learn from my edits, in one place for Settings, the sheet, History and the tests.
public enum LearnedText {
    public static let toggle = "Learn from my edits"
    public static let help = "When you fix a dictation right after Chirp inserts it, Chirp learns your words and each app's style. A fix counts once you make it twice. Kept on this Mac, encrypted."
    public static let offWithoutHistory = "Needs dictation history (above)."
    public static let title = "Learned"
    public static let empty = "Nothing learned yet"
    public static let emptyDetail = "Dictate, then fix a word in the same field. Fix it the same way twice and Chirp uses it from then on."
    public static let allApps = "Your words (every app)"

    public static func summary(_ items: [LearnedItem]) -> String {
        let active = items.filter { $0.state == .active }.count, learning = items.filter { $0.state == .learning }.count
        if items.isEmpty { return "Nothing yet" }
        return [active > 0 ? "\(active) in use" : nil, learning > 0 ? "\(learning) learning" : nil]
            .compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "All off"
    }

    public static func state(_ item: LearnedItem) -> String {
        switch item.state {
        case .active: "In use"
        case .learning: "Learning · \(min(item.count, LearnedStore.threshold - 1)) of \(LearnedStore.threshold)"
        case .off: "Off"
        }
    }

    public static func detail(_ item: LearnedItem) -> String {
        switch item.correction {
        case .term(let heard, let term): heard.lowercased() == term.lowercased() ? "Spelled \(term)" : "Heard as “\(heard)”"
        case .style(let style):
            switch style {
            case .lowercaseStart: "Messages start in lowercase in this app"
            case .noFinalPeriod: "No period at the end in this app"
            }
        }
    }

    public static func source(_ item: LearnedItem) -> String {
        "From your edit: “\(clip(item.inserted))” → “\(clip(item.edited))”" + (item.count > 1 ? " · seen \(item.count)×" : "")
    }

    static func clip(_ text: String, limit: Int = 60) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

/// One app's group in the Learned list: its style preferences and the words first learned in it.
public struct LearnedGroup: Identifiable, Equatable, Sendable {
    public var bundleID: String?
    public var title: String
    public var items: [LearnedItem]
    public var id: String { bundleID ?? "" }
}

@MainActor @Observable public final class LearnedModel {
    public var items: [LearnedItem] = []
    @ObservationIgnored public var icon: (String?) -> NSImage? = { HistoryModel.workspaceIcon($0) }
    @ObservationIgnored public var onSet: (UUID, LearnedItem.State) -> Void = { _, _ in }
    @ObservationIgnored public var onDelete: (UUID) -> Void = { _ in }
    @ObservationIgnored public var onReset: (String?) -> Void = { _ in }
    @ObservationIgnored public var onDone: () -> Void = {}

    public init() {}

    /// By app, the app with the most recent learning first; within an app, active items first, then newest.
    public var groups: [LearnedGroup] {
        let byApp = Dictionary(grouping: items) { $0.bundleID ?? "" }
        return byApp.map { key, items in
            LearnedGroup(bundleID: key.isEmpty ? nil : key, title: items.first?.appName ?? (key.isEmpty ? LearnedText.allApps : key),
                         items: items.sorted { ($0.state == .active ? 0 : 1, $1.lastSeen) < ($1.state == .active ? 0 : 1, $0.lastSeen) })
        }.sorted { ($0.items.map(\.lastSeen).max() ?? .distantPast) > ($1.items.map(\.lastSeen).max() ?? .distantPast) }
    }
}

/// The Learned list (Settings → Dictation → Learn from my edits → Show Learned…): what was learned, from which edit,
/// and whether it is in use, by app, with Approve / Undo / Delete each and Reset per app.
public struct LearnedView: View {
    @Bindable var model: LearnedModel

    public init(model: LearnedModel) { self.model = model }

    public static let size = CGSize(width: 560, height: 480)

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LearnedText.title).font(ChirpType.h2)
                    Text(LearnedText.summary(model.items)).font(ChirpType.meta).foregroundStyle(NotesInk.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 26, weight: .light)).foregroundStyle(NotesInk.tertiary)
                    Text(LearnedText.empty).font(.system(size: 13, weight: .semibold)).foregroundStyle(NotesInk.secondary)
                    Text(LearnedText.emptyDetail).font(.system(size: 11.5)).foregroundStyle(NotesInk.tertiary)
                        .multilineTextAlignment(.center).frame(maxWidth: 340)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(model.groups) { group in groupView(group) }
                    }
                    .padding(20)
                }
            }
            Divider()
            HStack {
                Text("Learned items never add words you didn’t say.").font(.system(size: 11)).foregroundStyle(NotesInk.tertiary)
                Spacer()
                Button("Done") { model.onDone() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color.chirp.background)
        .tint(Color.chirp.koi)
    }

    private func groupView(_ group: LearnedGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppIcon(image: model.icon(group.bundleID), size: 20)
                Text(group.title).font(.system(size: 13, weight: .semibold, design: .serif)).foregroundStyle(NotesInk.primary)
                Spacer()
                Button("Reset") { model.onReset(group.bundleID) }
                    .controlSize(.small)
                    .help("Forget everything learned from edits in \(group.title)")
            }
            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 12) }
                    row(item)
                }
            }
            .background(RoundedRectangle(cornerRadius: ChirpRadius.row).fill(Color.chirp.surface))
            .overlay(RoundedRectangle(cornerRadius: ChirpRadius.row).strokeBorder(NotesInk.tertiary.opacity(0.25)))
        }
    }

    private func row(_ item: LearnedItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.correction.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(NotesInk.primary)
                    StateChip(item: item)
                }
                Text(LearnedText.detail(item)).font(.system(size: 12)).foregroundStyle(NotesInk.secondary)
                Text(LearnedText.source(item)).font(.system(size: 11)).foregroundStyle(NotesInk.tertiary).lineLimit(2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                switch item.state {
                case .active: Button("Undo") { model.onSet(item.id, .off) }.help("Stop using this; Chirp won’t learn it again")
                case .learning, .off: Button("Approve") { model.onSet(item.id, .active) }.help("Use this from the next dictation")
                }
                Button {
                    model.onDelete(item.id)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete \(item.correction.title)")
                .help("Delete")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }
}

/// In use (lily), learning (moon) or off (muted): a word and a colour, never colour alone.
private struct StateChip: View {
    let item: LearnedItem

    var body: some View {
        let (fg, bg): (Color, Color) = switch item.state {
        case .active: (Color.chirp.lily, Color.chirp.lily.opacity(0.14))
        case .learning: (Color.chirp.moon, Color.chirp.moonFill.opacity(0.25))
        case .off: (Color.chirp.inkMuted, Color.chirp.inkMuted.opacity(0.14))
        }
        Text(LearnedText.state(item))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(bg))
            .fixedSize()
    }
}
