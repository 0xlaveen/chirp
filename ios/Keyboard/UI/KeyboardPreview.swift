import Foundation
import ChirpIOSCore
import KeyboardPolicy

#if DEBUG && targetEnvironment(simulator)
/// Simulator-only seam for screenshots: a one-word file `keyboard-preview` in the shared container pins the keyboard to
/// a named state with synthetic inputs (no session, armed, listening, polishing, finished, error, debug, noaccess; add
/// `+info` to open the ⓘ overlay). Never compiled into a device build or a Release build, never reads or writes text.
enum KeyboardPreview {
    static var preset: String? {
        guard let root = try? SharedConfiguration(bundle: .main).containerURL(),
              let text = try? String(contentsOf: root.appendingPathComponent("keyboard-preview"), encoding: .utf8) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static var opensInfo: Bool { preset?.hasSuffix("+info") == true }

    static func apply(to i: inout KeyboardInputs) {
        guard let name = preset?.replacingOccurrences(of: "+info", with: "") else { return }
        let now = i.now
        i.hasFullAccess = name != "noaccess"
        i.leaseUntil = now.addingTimeInterval(8)
        i.sessionExpiresAt = now.addingTimeInterval(252)
        i.styleID = "email"; i.availableStyleIDs = ["default", "chat", "email", "code", "notes"]
        i.errorCode = nil; i.isFinal = false; i.ownsUtterance = false; i.undoAvailable = false
        i.rawUntil = nil; i.recordingStartedAt = nil; i.debugRetention = false; i.fallback = nil; i.kept = false
        switch name {
        case "nosession": i.phase = nil
        case "armed": i.phase = .armed
        case "listening": i.phase = .listening; i.ownsUtterance = true; i.recordingStartedAt = now.addingTimeInterval(-12)
        case "polishing": i.phase = .correcting; i.ownsUtterance = true
        case "finished":
            i.phase = .finished; i.isFinal = true; i.ownsUtterance = true; i.undoAvailable = true
            i.rawUntil = now.addingTimeInterval(4); i.undoUntil = now.addingTimeInterval(4)
        case "kept": i.phase = .finished; i.kept = true; i.errorCode = .unreachable
        case "error": i.phase = .failed; i.errorCode = .unreachable
        case "debug": i.phase = .armed; i.debugRetention = true
        default: break
        }
    }
}
#endif
