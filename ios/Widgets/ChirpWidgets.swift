import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct ChirpWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ChirpSessionActivity()
        ChirpNotesActivity()
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
            .tint(Color.chirp.koi)
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
            .tint(Color.chirp.record)
        }
        .displayName("End Chirp session")
        .description("Turn off the Chirp session microphone.")
    }
}

struct ChirpSessionActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChirpActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ActivityGlyph(tone: tone(context), listening: context.state.phase == .listening || context.state.phase == .connecting)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.isStale ? "Status expired" : context.state.phase.headline)
                            .font(.headline).foregroundStyle(Color.chirp.ink)
                        Text(context.isStale ? "Open Chirp" : "Microphone active · idle audio discarded")
                            .font(.caption).foregroundStyle(Color.chirp.inkMuted)
                    }
                    Spacer(minLength: 8)
                    if !context.isStale, let since = context.state.listeningSince {
                        Text(since, style: .timer).font(ChirpType.timer(.title3)).fontWeight(.semibold)
                            .foregroundStyle(Color.chirp.ink).multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80, alignment: .trailing)
                    }
                }
                if context.isStale {
                    Label("Status expired · open Chirp", systemImage: "moon.stars.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.chirp.moon)
                }
                if context.state.debugRetention { DebugBanner() }
                SessionControls(phase: context.state.phase)
            }
            .pondActivityCard()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityGlyph(tone: tone(context), listening: context.state.phase == .listening, size: 30)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.isStale ? "Status expired" : context.state.phase.headline)
                        .font(.headline).foregroundStyle(Color.chirp.ink)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.isStale, let since = context.state.listeningSince {
                        Text(since, style: .timer).font(ChirpType.timer(.subheadline)).foregroundStyle(Color.chirp.ink)
                            .multilineTextAlignment(.trailing).frame(maxWidth: 56, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if context.isStale {
                            Label("Status expired · open Chirp", systemImage: "moon.stars.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(Color.chirp.moon)
                        }
                        if context.state.debugRetention { DebugBanner() }
                        SessionControls(phase: context.state.phase)
                    }
                }
            } compactLeading: {
                ActivityGlyph(tone: tone(context), listening: context.state.phase == .listening, size: 22)
                    .accessibilityHidden(false)
                    .accessibilityLabel(context.isStale ? "Chirp status expired; open Chirp" : "Chirp microphone active")
            } compactTrailing: {
                if context.state.debugRetention {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.chirp.record)
                        .accessibilityLabel("DEBUG recordings kept")
                } else if !context.isStale, let since = context.state.listeningSince {
                    Text(since, style: .timer).font(ChirpType.timer(.caption)).foregroundStyle(Color.chirp.koi)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 44)
                } else {
                    Image(systemName: context.isStale ? "moon.stars.fill" : "waveform")
                        .foregroundStyle(context.isStale ? Color.chirp.moon : Color.chirp.koi)
                        .accessibilityLabel(context.isStale ? "Chirp status expired" : "Chirp session")
                }
            } minimal: {
                ActivityGlyph(tone: tone(context), listening: context.state.phase == .listening, size: 22)
                    .accessibilityHidden(false)
                    .accessibilityLabel(context.state.debugRetention ? "DEBUG recordings kept" : context.isStale ? "Chirp status expired" : "Chirp microphone active")
            }
        }
    }

    /// DEBUG retention and errors are `record`, a stale status is the moon, everything else koi.
    private func tone(_ context: ActivityViewContext<ChirpActivityAttributes>) -> ActivityGlyph.Tone {
        if context.state.debugRetention || context.state.phase == .failed { return .record }
        return context.isStale ? .moon : .koi
    }
}

private struct SessionControls: View {
    var phase: ChirpActivityAttributes.Phase

    var body: some View {
        HStack(spacing: 8) {
            if phase == .listening || phase == .connecting {
                Button(intent: StopChirpIntent()) { ActivityCapsule(title: "Stop", symbol: "stop.fill", style: .record) }
                Button(intent: CancelChirpIntent()) { ActivityCapsule(title: "Cancel", symbol: "xmark", style: .quiet) }
            } else {
                Button(intent: StartChirpIntent()) { ActivityCapsule(title: "Start", symbol: "mic.fill", style: .koi) }
                Button(intent: CancelChirpIntent()) { ActivityCapsule(title: "Cancel", symbol: "xmark", style: .quiet) }
            }
            Spacer(minLength: 0)
            Button(intent: EndChirpSessionIntent()) { ActivityCapsule(title: "End session", symbol: "mic.slash", style: .recordOutline) }
        }
        .buttonStyle(.plain)
    }
}
