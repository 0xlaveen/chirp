import Foundation

/// Mirror of `ChirpIOSCore.DiagnosticCode` (same raw values); this package has no Shared dependency.
public enum KeyboardError: String, Sendable, CaseIterable {
    case auth, busy, tooLong, badAudio, badRequest, engine, unreachable, timeout, permission, interrupted, storage, unknown
    case offline, notFound, secure

    /// The one-line cause shown in the strip, with the fix behind the ⓘ (`guidance`). Fixed and content-free too.
    public var cause: String {
        switch self {
        case .unreachable: "Computer offline"
        case .offline: "Device offline"
        case .notFound: "Computer not found"
        case .secure: "Connection not secure"
        case .timeout: "Server timed out"
        case .auth: "Computer refused this device"
        case .permission: "Microphone is off"
        case .interrupted: "Recording interrupted"
        case .busy: "Server busy"
        case .tooLong: "Length limit reached"
        case .storage: "Shared storage unavailable"
        case .badAudio: "Audio wasn't usable"
        case .badRequest: "Clean-up prompt too long"
        case .engine: "Speech engine failed"
        case .unknown: "Dictation failed"
        }
    }

    /// Short, fixed, content-free guidance. Never includes transcript, host or server text.
    public var guidance: String {
        switch self {
        case .unreachable: "Can't reach your computer. Is it awake, with Chirp running and Tailscale on?"
        case .offline: "This device is offline. Connect to a network and try again."
        case .notFound: "Can't find your computer on the tailnet. Is it online, with Tailscale on here?"
        case .secure: "Couldn't make a secure connection to your computer."
        case .timeout: "The server took too long. Try again."
        case .auth: "Your computer refused this device. Pair again in Chirp."
        case .permission: "Microphone is off. Allow it in the Chirp app, then try again."
        case .interrupted: "Recording was interrupted. Start again."
        case .busy: "The server is busy. Try again in a moment."
        case .tooLong: "That dictation hit the length limit. Start a new one."
        case .storage: "Chirp can't use its shared storage. Open Chirp to check setup."
        case .badAudio: "The audio wasn't usable. Try again."
        case .badRequest: "The clean-up prompt is too long. Shorten it in Settings → Dictation → Styles."
        case .engine: "The speech engine failed. Try again."
        case .unknown: "Something went wrong. Open Chirp for details."
        }
    }
}
