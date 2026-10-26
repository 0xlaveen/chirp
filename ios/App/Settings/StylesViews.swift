import ChirpCore
import ChirpIOSCore
import SwiftUI

// The Styles list and its prompt editor (#194), moved from SettingsViews.swift: Styles is no longer its
// own tab — it lives under Settings → Dictation. The list selects (checkmark on the selected style, a
// moon "Edited" capsule when the prompt was changed); each row's pencil opens the PromptEditor.

/// The Styles group of Settings → Dictation: server style rows plus Refresh styles.
struct StylesList: View {
    @ObservedObject var model: SessionCoordinator
    var body: some View {
        SettingsGroup(title: "Styles") {
            if model.profiles.isEmpty {
                SettingsItem {
                    Text(model.paired ? "Style prompts unavailable. Check your computer connection and refresh."
                                      : "Connect to your computer to load authenticated style prompts.")
                        .font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                }
            }
            ForEach(model.profiles) { profile in
                StyleRow(model: model, profile: profile)
            }
            ActionRow(title: "Refresh styles", symbol: "arrow.clockwise", disabled: !model.paired,
                      identifier: "chirp.styles.refresh") {
                Task { await model.loadProfiles() }
            }
        }
    }
}

/// One style: tap selects it; the pencil opens its prompt editor. The checkmark follows the selection,
/// "Edited" appears when its prompt differs from the server's, and rewrites say so.
private struct StyleRow: View {
    @ObservedObject var model: SessionCoordinator
    let profile: CorrectionProfile
    private var selected: Bool { profile.selected(model) }
    private var edited: Bool { model.preferences.prompts[profile.id] != nil }
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        RowTile(hasSummary: true) {
            if typeSize.isAccessibilitySize {
                // The pick text at the full row width; the selection mark and pencil on their own line (#271 A2-2).
                VStack(alignment: .leading, spacing: ChirpSpacing.s8) {
                    pick
                    HStack(spacing: ChirpSpacing.s8) {
                        mark
                        Spacer(minLength: 0)
                        edit
                    }
                }
            } else {
                pick
                mark
                edit
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(profile.name)\(selected ? ", Selected" : "")\(edited ? ", Edited" : "")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("chirp.styles.row." + profile.id)
    }

    private var pick: some View {
        Button { model.selectStyle(profile.id) } label: {
            let text = RowText(title: profile.name,
                               summary: profile.rewrites ? profile.description + " · May restructure" : profile.description,
                               symbol: nil)
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: ChirpSpacing.s8) {
                        text
                        if edited { editedCapsule }
                    }
                } else {
                    HStack(spacing: ChirpSpacing.s8) {
                        text
                        if edited { editedCapsule }
                        Spacer(minLength: ChirpSpacing.s4)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.rowPress)
        .accessibilityIdentifier("chirp.styles.pick." + profile.id)
    }

    private var mark: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .symbolRenderingMode(.hierarchical)
            .font(.title3).foregroundStyle(selected ? Color.chirp.koi : Color.chirp.inkMuted)
            .accessibilityHidden(!selected)
            .accessibilityLabel(selected ? "Selected" : "")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var edit: some View {
        NavigationLink { PromptEditor(model: model, profile: profile) } label: {
            Image(systemName: "square.and.pencil").font(.body)
                .foregroundStyle(Color.chirp.inkMuted).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Edit \(profile.name) prompt")
        .accessibilityIdentifier("chirp.styles.edit." + profile.id)
    }

    private var editedCapsule: some View {
        Text("Edited").font(.caption2.weight(.semibold))
            .foregroundStyle(Color.chirp.moon)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.chirp.moonFill.opacity(0.35), in: Capsule())
            .accessibilityHidden(true)
    }
}


private extension CorrectionProfile {
    /// The row and the editor both ask whether this profile is the selected style.
    @MainActor func selected(_ model: SessionCoordinator) -> Bool { model.preferences.styleID == id }
}

/// A style's editable prompt (moved from SettingsViews.swift): description, Select, the prompt with its
/// character count, and Reset to server default.
struct PromptEditor: View {
    @ObservedObject var model: SessionCoordinator
    let profile: CorrectionProfile
    private var prompt: Binding<String> {
        Binding(get: { model.preferences.prompts[profile.id] ?? profile.prompt },
                set: { model.editPrompt($0, profile: profile) })
    }
    var body: some View {
        SettingsPageScroll {
            SettingsGroup {
                SettingsItem {
                    Text(profile.description).font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                    if profile.rewrites { Text("May restructure your text").font(.footnote).foregroundStyle(Color.chirp.moon) }
                    if profile.selected(model) {
                        Button("Selected") {}.buttonStyle(.capsuleChip).disabled(true)
                    } else {
                        Button("Select this style") { model.selectStyle(profile.id) }.buttonStyle(.pondTonal)
                            .accessibilityIdentifier("chirp.styles.select." + profile.id)
                    }
                }
            }
            SettingsGroup(title: "Editable style prompt") {
                SettingsItem {
                    TextEditor(text: prompt).frame(minHeight: 220).scrollContentBackground(.hidden)
                        .padding(ChirpSpacing.s8)
                        .background(Color.chirp.surfaceRaised, in: RoundedRectangle(cornerRadius: ChirpRadius.row, style: .continuous))
                        .accessibilityLabel("Style prompt")
                        .accessibilityIdentifier("chirp.styles.prompt")
                    Text("\(prompt.wrappedValue.unicodeScalars.count) / \(min(4000, profile.maxPromptChars)) characters")
                        .font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                        .accessibilityIdentifier("chirp.styles.count")
                    Button("Reset to server default") { model.resetPrompt(profile.id) }
                        .buttonStyle(.capsuleChip)
                        .disabled(model.preferences.prompts[profile.id] == nil)
                        .accessibilityIdentifier("chirp.styles.reset")
                }
            }
            SettingsItem {
                Text("Chirp adds fixed safety rules. Editable prompts cannot make it answer or execute instructions.")
                    .font(.footnote).foregroundStyle(Color.chirp.inkMuted)
            }
        }.navigationTitle(profile.name)
    }
}
