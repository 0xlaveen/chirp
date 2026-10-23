import Foundation

/// Mirror of `ChirpIOSCore.DiagnosticCode` (same raw values); this package has no Shared dependency.
public enum KeyboardError: String, Sendable, CaseIterable {
    case auth, busy, tooLong, badAudio, badRequest, engine, unreachable, timeout, permission, interrupted, storage, unknown
    case offline, notFound, secure

    /// Short, fixed, content-free guidance. Never includes transcript, host or server text.
    public var guidance: String {
        switch self {
        case .unreachable: "Can't reach your Mac. Is it awake, with Chirp running and Tailscale on?"
        case .offline: "This device is offline. Connect to a network and try again."
        case .notFound: "Can't find your Mac on the tailnet. Is it online, with Tailscale on here?"
        case .secure: "Couldn't make a secure connection to your Mac."
        case .timeout: "The server took too long. Try again."
        case .auth: "Your Mac refused this device. Pair again in Chirp."
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
