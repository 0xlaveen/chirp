import Foundation

/// Mirror of `ChirpIOSCore.DiagnosticCode` (same raw values); this package has no Shared dependency.
public enum KeyboardError: String, Sendable, CaseIterable {
    case auth, busy, tooLong, badAudio, badRequest, engine, unreachable, timeout, permission, interrupted, storage, unknown

    /// Short, fixed, content-free guidance. Never includes transcript, host or server text.
    public var guidance: String {
        switch self {
        case .unreachable: "Can't reach your Mac. Check Tailscale and that Chirp is running on it."
        case .timeout: "The server took too long. Try again."
        case .auth: "The server rejected this phone. Re-pair in Chirp."
        case .permission: "Microphone is off. Allow it in the Chirp app, then try again."
        case .interrupted: "Recording was interrupted. Start again."
        case .busy: "The server is busy. Try again in a moment."
        case .tooLong: "That dictation hit the length limit. Start a new one."
        case .storage: "Chirp can't use its shared storage. Open Chirp to check setup."
        case .badAudio: "The audio wasn't usable. Try again."
        case .badRequest: "The server refused the request. Check Chirp's settings."
        case .engine: "The speech engine failed. Try again."
        case .unknown: "Something went wrong. Open Chirp for details."
        }
    }
}
