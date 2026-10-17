import Foundation

/// An audio input device as the menu lists it.
public struct AudioInput: Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public enum InputSelection {
    /// The device to record from. The picked device while it is connected; otherwise nil, which means "follow the
    /// system default input" (also the answer when nothing was picked, or the picked device was unplugged).
    public static func resolve(chosen: String?, available: [AudioInput]) -> AudioInput? {
        guard let chosen else { return nil }
        return available.first { $0.uid == chosen }
    }
}

/// What "Open doctor output" copies: the commands that print the server's read-only diagnostics.
public enum DoctorHelp {
    public static func clipboardText(serverURL: String) -> String {
        """
        # Chirp server diagnostics (read-only; Chirp is pointed at \(serverURL))
        cd <your chirp checkout>/server
        uv run chirp-server doctor --quick   # skips the model load
        uv run chirp-server doctor           # full run, including a model load and fixture decode
        """
    }
}
