import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Live Notes on the lock screen and in the Dynamic Island: the state, the elapsed time (counted by the system while
/// recording, so a locked phone needs no updates) and Pause/Resume and Stop. Never any text of the notes; the note title is the one piece of content, set by the app (<= 60 characters).
struct ChirpNotesActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChirpNotesActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                Text(context.state.title ?? "Live Notes")
                    .font(.system(.headline, design: .serif).weight(.semibold))
                    .foregroundStyle(Color.chirp.ink).lineLimit(1)
                HStack(spacing: 8) {
                    NotesStatusLine(state: context.state)
                    Spacer(minLength: 8)
                    NotesElapsed(state: context.state).font(ChirpType.timer(.title3)).fontWeight(.semibold)
                        .foregroundStyle(Color.chirp.ink).frame(maxWidth: 96, alignment: .trailing)
                }
                if context.state.debugRetention { DebugBanner() }
                NotesControls(state: context.state)
            }
            .pondActivityCard()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityGlyph(tone: context.state.debugRetention ? .record : .koi, listening: context.state.status == .recording, size: 30)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title ?? "Live Notes")
                        .font(.system(.headline, design: .serif).weight(.semibold)).foregroundStyle(Color.chirp.ink).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    NotesElapsed(state: context.state).font(ChirpType.timer(.subheadline)).foregroundStyle(Color.chirp.ink)
                        .frame(maxWidth: 64, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        NotesStatusLine(state: context.state)
                        if context.state.debugRetention { DebugBanner() }
                        NotesControls(state: context.state)
                    }
                }
            } compactLeading: {
                if context.state.status == .paused {
                    Image(systemName: "pause.fill").foregroundStyle(Color.chirp.koi).accessibilityLabel(context.state.status.label)
                } else {
                    ActivityGlyph(tone: context.state.debugRetention ? .record : .koi, listening: context.state.status == .recording, size: 22)
                        .accessibilityHidden(false).accessibilityLabel(context.state.status.label)
                }
            } compactTrailing: {
                NotesElapsed(state: context.state).font(ChirpType.timer(.caption)).frame(maxWidth: 52)
                    .foregroundStyle(context.state.debugRetention ? Color.chirp.record : Color.chirp.koi)
            } minimal: {
                Image(systemName: context.state.debugRetention ? "exclamationmark.triangle.fill" : context.state.status == .paused ? "pause.fill" : "waveform")
                    .foregroundStyle(context.state.debugRetention ? Color.chirp.record : Color.chirp.koi)
                    .accessibilityLabel(context.state.status.label)
            }
        }
    }
}

/// "● Recording": the `record` dot while capturing, the moon-less quiet text while paused or finishing.
private struct NotesStatusLine: View {
    let state: ChirpNotesActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 6) {
            if state.status == .recording || state.status == .offline { RecordDot() }
            else { Image(systemName: state.status == .paused ? "pause.fill" : "ellipsis").font(.caption2).foregroundStyle(Color.chirp.inkMuted) }
            Text(state.status.headline).font(.subheadline.weight(.medium))
                .foregroundStyle(state.status == .offline ? Color.chirp.moon : Color.chirp.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.status.label)
    }
}

private struct NotesElapsed: View {
    let state: ChirpNotesActivityAttributes.ContentState
    var body: some View {
        if state.counting {
            Text(state.startedAt, style: .timer).multilineTextAlignment(.trailing)
        } else {
            Text(ChirpNotesActivityAttributes.ContentState.clock(state.elapsed))
        }
    }
}

private struct NotesControls: View {
    let state: ChirpNotesActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 8) {
            if state.status != .finishing {
                Button(intent: PauseChirpNotesIntent()) {
                    state.status == .paused
                        ? ActivityCapsule(title: "Resume", symbol: "mic.fill", style: .koi)
                        : ActivityCapsule(title: "Pause", symbol: "pause.fill", style: .quiet)
                }
                Button(intent: StopChirpNotesIntent()) { ActivityCapsule(title: "Stop", symbol: "stop.fill", style: .record) }
            }
        }
        .buttonStyle(.plain)
    }
}
