import ChirpCore
import SwiftUI

/// The toolbar's Sources button (#211): the microphone, or the microphone with call audio. Its popover is the picker.
struct SourcesButton: View {
    @Bindable var model: NotesModel

    var body: some View {
        Button {
            if !model.showsSources { model.onRefreshCallApps() }
            model.showsSources.toggle()
        } label: {
            Label(NotesSourcesText.title, systemImage: model.sources.callAudio ? "person.2.wave.2" : "mic")
                .foregroundStyle(model.sources.callAudio ? AnyShapeStyle(Color.chirp.koi) : AnyShapeStyle(.primary))
        }
        .help(NotesSourcesText.toolbarHelp + " (now: \(model.sources.title))")
        .accessibilityLabel("Sources: \(model.sources.title)")
        .popover(isPresented: $model.showsSources, arrowEdge: .bottom) {
            SourcesPanel(model: model)
        }
    }
}

/// The picker: two source rows, the app call audio comes from, what is captured and where it goes. Turning call audio
/// on the first time shows the explanation (what is recorded, the one-time macOS prompt) before anything changes.
struct SourcesPanel: View {
    let model: NotesModel

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pending = model.explainingCallAudio {
                CallAudioExplanation(model: model, pending: pending)
            } else {
                picker
            }
        }
        .frame(width: Self.width)
        .background(Color.chirp.surface)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s8) {
            Text(NotesSourcesText.title)
                .font(ChirpType.listTitle)
                .foregroundStyle(NotesInk.primary)
                .padding(.bottom, 2)
            SourceRow(symbol: "mic", title: NotesSourcesText.microphone, detail: NotesSourcesText.microphoneDetail,
                      selected: !model.sources.callAudio, enabled: model.canChangeSources) {
                model.onSourcesChange(NotesSources(callAudio: false, app: model.sources.app))
            }
            SourceRow(symbol: "person.2.wave.2", title: NotesSourcesText.call, detail: NotesSourcesText.callDetail,
                      selected: model.sources.callAudio, enabled: model.canChangeSources && model.callAudioAvailable) {
                model.onSourcesChange(NotesSources(callAudio: true, app: model.sources.app))
            }
            if model.sources.callAudio {
                HStack(spacing: ChirpSpacing.s8) {
                    Text(NotesSourcesText.from)
                        .font(ChirpType.meta)
                        .foregroundStyle(NotesInk.secondary)
                    Picker(NotesSourcesText.from, selection: Binding(
                        get: { model.sources.app?.bundleID ?? "" },
                        set: { id in
                            let app = model.callApps.first { $0.bundleID == id }
                            model.onSourcesChange(NotesSources(callAudio: true, app: app))
                        })) {
                        Text(NotesSourcesText.allAudio).tag("")
                        if !model.callApps.isEmpty { Divider() }
                        ForEach(model.callApps, id: \.bundleID) { app in Text(app.name).tag(app.bundleID) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(!model.canChangeSources)
                }
                .padding(.leading, 36)
                Label(NotesSourcesText.youLabel, systemImage: "person.crop.circle")
                    .font(ChirpType.meta)
                    .foregroundStyle(NotesInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 36)
            }
            if !model.canChangeSources {
                Text(NotesSourcesText.locked)
                    .font(ChirpType.meta)
                    .foregroundStyle(Color.chirp.moon)
            } else if !model.callAudioAvailable {
                Text(NotesSourcesText.unavailable)
                    .font(ChirpType.meta)
                    .foregroundStyle(NotesInk.secondary)
            }
            Divider().padding(.vertical, 4)
            Label(NotesSourcesText.privacy, systemImage: "lock.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(NotesInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ChirpSpacing.s16)
    }
}

/// One source: a radio dot, its symbol in a koi disc when chosen, the title and what it captures.
private struct SourceRow: View {
    let symbol: String
    let title: String
    let detail: String
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ChirpSpacing.s12) {
                ZStack {
                    Circle().fill(selected ? Color.chirp.koiContainer : Color.chirp.surfaceRaised)
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Color.chirp.onKoiContainer : NotesInk.secondary)
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(NotesInk.primary)
                    Text(detail).font(ChirpType.meta).foregroundStyle(NotesInk.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.chirp.koi : NotesInk.tertiary)
            }
            .padding(.horizontal, ChirpSpacing.s8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: ChirpRadius.row)
                .fill(selected ? Color.chirp.koiContainer.opacity(0.35) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: ChirpRadius.row)
                .strokeBorder(selected ? Color.chirp.koi.opacity(0.45) : Color.chirp.surfaceRaised, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled || selected ? 1 : 0.5)
        .accessibilityLabel("\(title): \(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Before call audio is first turned on: what it records, the one-time macOS prompt, where the audio goes.
private struct CallAudioExplanation: View {
    let model: NotesModel
    let pending: NotesSources

    var body: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s12) {
            HStack(spacing: ChirpSpacing.s12) {
                ZStack {
                    Circle().fill(Color.chirp.koiContainer)
                    Image(systemName: "person.2.wave.2")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.chirp.onKoiContainer)
                }
                .frame(width: 34, height: 34)
                Text(NotesSourcesText.explainTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NotesInk.primary)
            }
            Text(NotesSourcesText.explainBody)
                .font(.system(size: 13))
                .foregroundStyle(NotesInk.primary)
                .fixedSize(horizontal: false, vertical: true)
            Label(NotesSourcesText.youLabel, systemImage: "person.crop.circle")
                .font(ChirpType.meta)
                .foregroundStyle(NotesInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(NotesSourcesText.explainPermission, systemImage: "checkmark.shield")
                .font(ChirpType.meta)
                .foregroundStyle(NotesInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(NotesSourcesText.privacy, systemImage: "lock.fill")
                .font(ChirpType.meta)
                .foregroundStyle(NotesInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(NotesSourcesText.notNow) { model.onCallAudioExplained(false) }
                    .keyboardShortcut(.cancelAction)
                Button(NotesSourcesText.continueLabel) { model.onCallAudioExplained(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(ChirpSpacing.s16)
    }
}

/// While a call recording runs: what is being captured, with a lock (the privacy line for call audio).
struct SourcesChip: View {
    let sources: NotesSources

    var body: some View {
        Label(NotesSourcesText.chip(sources), systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(NotesInk.secondary)
            .lineLimit(1)
            .help(NotesSourcesText.capturing(sources) + ". " + NotesSourcesText.privacy)
            .accessibilityLabel(NotesSourcesText.capturing(sources))
    }
}

/// A call-audio problem while recording, with the way to fix it.
struct CallNoticeLine: View {
    let model: NotesModel
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ChirpSpacing.s8) {
            Label(text, systemImage: "speaker.slash")
                .font(.caption)
                .foregroundStyle(Color.chirp.moon)
                .lineLimit(2)
                .help(text)
            Button(NotesSourcesText.openSettings, action: model.onOpenCallAudioSettings)
                .buttonStyle(.link)
                .font(.caption)
                .fixedSize()
        }
    }
}
