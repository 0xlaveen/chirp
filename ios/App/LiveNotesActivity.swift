@preconcurrency import ActivityKit
import Foundation

/// What Live Notes needs from ActivityKit; tests pass closures that record the calls.
struct NotesActivityControl {
    var begin: (ChirpNotesActivityAttributes.ContentState) throws -> Void
    var update: (ChirpNotesActivityAttributes.ContentState) async -> Void
    var end: () async -> Void

    static var none: Self { Self(begin: { _ in }, update: { _ in }, end: {}) }
    @MainActor static let system = NotesActivityControl(begin: { try NotesLiveActivity.begin($0) },
                                                        update: { await NotesLiveActivity.update($0) },
                                                        end: { await NotesLiveActivity.end() })
}

/// App target only. Unlike the keyboard session's activity it is not a microphone lease: recording works without it
/// (Live Activities off), the lock screen just has no controls then.
@MainActor
enum NotesLiveActivity {
    private static var activity: Activity<ChirpNotesActivityAttributes>?

    enum Unavailable: Error { case disabled }

    static func begin(_ state: ChirpNotesActivityAttributes.ContentState) throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw Unavailable.disabled }
        guard activity == nil else { return }
        for previous in Activity<ChirpNotesActivityAttributes>.activities {
            Task { await previous.end(nil, dismissalPolicy: .immediate) }
        }
        activity = try Activity.request(attributes: ChirpNotesActivityAttributes(), content: ActivityContent(state: state, staleDate: nil),
                                        pushType: nil)
    }

    static func update(_ state: ChirpNotesActivityAttributes.ContentState) async {
        await activity?.update(ActivityContent(state: state, staleDate: nil))
    }

    static func end() async {
        let ending = activity
        activity = nil
        await ending?.end(nil, dismissalPolicy: .immediate)
    }
}
