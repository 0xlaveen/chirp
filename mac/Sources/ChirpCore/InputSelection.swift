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
        if command -v chirp-server >/dev/null 2>&1; then
            chirp-server doctor --quick
            chirp-server doctor
        elif [ -x server/.venv/bin/chirp-server ]; then
            server/.venv/bin/chirp-server doctor --quick
            server/.venv/bin/chirp-server doctor
        elif [ -x .venv/bin/chirp-server ]; then
            .venv/bin/chirp-server doctor --quick
            .venv/bin/chirp-server doctor
        else
            echo 'Run these diagnostics from your Chirp checkout or its server directory, or add chirp-server to PATH.'
        fi
        """
    }
}
