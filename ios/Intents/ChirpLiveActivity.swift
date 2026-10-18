import ActivityKit
import Foundation

/// App target only. Begin successfully BEFORE enabling capture, including idle
/// capture. Failure is a recording precondition failure, not an optional warning.
@MainActor
enum ChirpLiveActivity {
    private static var activity: Activity<ChirpActivityAttributes>?

    enum Unavailable: LocalizedError {
        case disabled
        var errorDescription: String? { "Enable Live Activities for Chirp, then open Chirp to start a session." }
    }

    static func begin(debugRetention: Bool) throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw Unavailable.disabled }
        guard activity == nil else { return }
        // Dismiss orphaned UI from a terminated process; it is not a valid mic lease.
        for previous in Activity<ChirpActivityAttributes>.activities {
            Task { await previous.end(nil, dismissalPolicy: .immediate) }
        }
        activity = try Activity.request(
            attributes: ChirpActivityAttributes(),
            content: ActivityContent(state: .init(phase: .armed, debugRetention: debugRetention), staleDate: Date().addingTimeInterval(15)),
            pushType: nil
        )
    }

    static func update(phase: String, debugRetention: Bool) async {
        await activity?.update(ActivityContent(
            state: .init(phase: .init(coordinatorPhase: phase), debugRetention: debugRetention), staleDate: Date().addingTimeInterval(15)
        ))
    }

    static var isActive: Bool {
        guard let activity else { return false }
        return activity.activityState == .active
    }

    static func end() async {
        let ending = activity
        activity = nil
        await ending?.end(nil, dismissalPolicy: .immediate)
    }
}
