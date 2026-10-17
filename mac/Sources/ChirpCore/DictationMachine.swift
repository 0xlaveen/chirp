import Foundation

public enum DictationState: Sendable, Equatable {
    case idle, connecting, listening, finalizing
    /// The server is cleaning up the transcript (it sent `correcting`); the raw text is on screen as "Polishing…".
    case correcting
    case inserting
    case error(String)

    public var isActive: Bool {
        switch self {
        case .connecting, .listening, .finalizing, .correcting, .inserting: true
        case .idle, .error: false
        }
    }
}

public enum DictationEvent: Sendable, Equatable {
    case hotkeyDown(at: TimeInterval)
    case hotkeyUp(at: TimeInterval)
    case escape
    case serverReady
    /// The server started clean-up on the final transcript (`correcting`).
    case correctingReceived
    case finalReceived
    /// Clean-up did not deliver: the client timeout elapsed, or the server errored or the socket closed while it
    /// ran. The raw transcript is inserted instead.
    case correctionFailed
    case insertionFinished
    /// Server error, lost connection, mic failure, finalize timeout, no signal.
    case failed(String)
}

public enum DictationEffect: Sendable, Equatable {
    /// Start capturing and open the socket.
    case start
    /// Stop capturing and ask the server for the final transcript.
    case finalize
    /// Stop capturing, tell the server to discard, insert nothing.
    case cancel
    /// Release everything after a failure and show the message.
    case abort(String)
    case insert
}

/// Pure state machine: idle → connecting → listening → finalizing → [correcting →] inserting → idle (+ error).
/// A press shorter than `tapThreshold` toggles; a longer press is push-to-talk until release.
public struct DictationMachine: Sendable {
    public static let tapThreshold: TimeInterval = 0.3

    public private(set) var state: DictationState = .idle
    /// Set while the activating key is still down and its press length is undecided.
    private var pressStart: TimeInterval?

    public init() {}

    @discardableResult
    public mutating func handle(_ event: DictationEvent) -> [DictationEffect] {
        switch (state, event) {
        case (.idle, .hotkeyDown(let t)), (.error, .hotkeyDown(let t)):
            state = .connecting
            pressStart = t
            return [.start]

        case (.connecting, .hotkeyDown), (.listening, .hotkeyDown):
            // Already recording. A new press while the first is undecided is key repeat; otherwise it's the toggle-off tap.
            guard pressStart == nil else { return [] }
            state = .finalizing
            return [.finalize]

        case (.connecting, .hotkeyUp(let t)), (.listening, .hotkeyUp(let t)):
            guard let start = pressStart else { return [] }
            pressStart = nil
            if t - start < Self.tapThreshold { return [] }   // tap: keep recording until the next tap
            state = .finalizing                                // hold released: push-to-talk
            return [.finalize]

        case (.connecting, .serverReady):
            state = .listening
            return []

        case (.connecting, .escape), (.listening, .escape), (.finalizing, .escape), (.correcting, .escape):
            pressStart = nil
            state = .idle
            return [.cancel]

        case (.finalizing, .correctingReceived):
            state = .correcting
            return []

        case (.finalizing, .finalReceived), (.correcting, .finalReceived), (.correcting, .correctionFailed):
            state = .inserting
            return [.insert]

        case (.inserting, .insertionFinished):
            state = .idle
            return []

        case (.connecting, .failed(let m)), (.listening, .failed(let m)), (.finalizing, .failed(let m)),
             (.correcting, .failed(let m)):
            pressStart = nil
            state = .error(m)
            return [.abort(m)]

        case (.inserting, .failed(let m)):
            state = .error(m)
            return []

        default:
            return []
        }
    }

    /// Dismiss an error banner without starting a new session.
    public mutating func dismissError() {
        if case .error = state { state = .idle }
    }
}
