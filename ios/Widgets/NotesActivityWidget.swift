import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Live Notes on the lock screen and in the Dynamic Island: the state, the elapsed time (counted by the system while
/// recording, so a locked phone needs no updates) and Pause/Resume and Stop. Never any text of the notes.
struct ChirpNotesActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChirpNotesActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Chirp Live Notes", systemImage: "note.text").font(.headline)
                    Spacer()
                    NotesElapsed(state: context.state).font(.title3.monospacedDigit().bold())
                }
                Text(context.state.status.label).font(.caption)
                if context.state.debugRetention {
                    Label("DEBUG recordings kept", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                }
                NotesControls(state: context.state)
            }
            .padding()
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("Notes", systemImage: "note.text") }
                DynamicIslandExpandedRegion(.trailing) { NotesElapsed(state: context.state).monospacedDigit() }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack {
                        Text(context.state.status.label).font(.caption)
                        if context.state.debugRetention { Text("DEBUG recordings kept").foregroundStyle(.red).font(.caption) }
                        NotesControls(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.status == .paused ? "pause.fill" : "note.text")
                    .accessibilityLabel(context.state.status.label)
            } compactTrailing: {
                NotesElapsed(state: context.state).monospacedDigit().frame(maxWidth: 52)
                    .foregroundStyle(context.state.debugRetention ? Color.red : Color.primary)
            } minimal: {
                Image(systemName: context.state.debugRetention ? "exclamationmark.triangle.fill" : context.state.status == .paused ? "pause.fill" : "note.text")
                    .foregroundStyle(context.state.debugRetention ? Color.red : Color.primary)
                    .accessibilityLabel(context.state.status.label)
            }
        }
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
        HStack {
            if state.status != .finishing {
                Button(intent: PauseChirpNotesIntent()) {
                    state.status == .paused ? Label("Resume", systemImage: "mic.fill") : Label("Pause", systemImage: "pause.fill")
                }
                Button(intent: StopChirpNotesIntent()) { Label("Stop", systemImage: "stop.fill") }
            }
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }
}
