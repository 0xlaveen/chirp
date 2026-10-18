import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct ChirpWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ChirpSessionActivity()
        ChirpStartControl()
        ChirpEndControl()
    }
}

struct ChirpStartControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.chirp.ios.start") {
            ControlWidgetButton(action: StartChirpIntent()) {
                Label("Start dictation", systemImage: "mic.fill")
            }
        }
        .displayName("Chirp dictation")
        .description("Open Chirp to start dictation. Setup and microphone permission are required.")
    }
}

struct ChirpEndControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.chirp.ios.end") {
            ControlWidgetButton(action: EndChirpSessionIntent()) {
                Label("End session", systemImage: "mic.slash.fill")
            }
        }
        .displayName("End Chirp session")
        .description("Turn off the Chirp session microphone.")
    }
}

struct ChirpSessionActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChirpActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label("Chirp", systemImage: "mic.fill").font(.headline)
                Text(context.state.phase.label).font(.caption)
                if context.isStale { Text("Status expired · open Chirp").foregroundStyle(.orange) }
                if context.state.debugRetention {
                    Label("DEBUG recordings kept", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                SessionControls()
            }
            .padding()
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("Chirp", systemImage: "mic.fill") }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: EndChirpSessionIntent()) { Label("End session", systemImage: "mic.slash") }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack {
                        Text(context.isStale ? "Status expired · open Chirp" : context.state.phase.label)
                            .font(.caption)
                        if context.state.debugRetention { Text("DEBUG recordings kept").foregroundStyle(.red).font(.caption) }
                        SessionControls()
                    }
                }
            } compactLeading: {
                Image(systemName: context.isStale ? "questionmark.circle" : "mic.fill")
                    .accessibilityLabel(context.isStale ? "Chirp status expired; open Chirp" : "Chirp microphone active")
            } compactTrailing: {
                Image(systemName: context.state.debugRetention ? "exclamationmark.triangle.fill" : context.isStale ? "questionmark.circle" : "waveform")
                    .foregroundStyle(context.state.debugRetention ? Color.red : Color.primary)
                    .accessibilityLabel(context.state.debugRetention ? "DEBUG recordings kept" : context.isStale ? "Chirp status expired" : "Chirp session")
            } minimal: {
                Image(systemName: context.state.debugRetention ? "exclamationmark.triangle.fill" : context.isStale ? "questionmark.circle" : "mic.fill")
                    .foregroundStyle(context.state.debugRetention ? Color.red : Color.primary)
                    .accessibilityLabel(context.state.debugRetention ? "DEBUG recordings kept" : context.isStale ? "Chirp status expired" : "Chirp microphone active")
            }
        }
    }
}

private struct SessionControls: View {
    var body: some View {
        HStack {
            Button(intent: StartChirpIntent()) { Label("Start", systemImage: "mic") }
            Button(intent: StopChirpIntent()) { Label("Stop", systemImage: "stop.fill") }
            Button(intent: CancelChirpIntent()) { Label("Cancel", systemImage: "xmark") }
            Button(intent: EndChirpSessionIntent()) { Label("End session", systemImage: "mic.slash") }
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }
}
