import os

/// Diagnostics only: hotkey registration, key press/release, state changes and permission status.
/// Never log audio, partial/final text, tokens or field contents.
/// Read with: /usr/bin/log stream --predicate 'subsystem == "dev.chirp.mac"'
public let chirpLog = Logger(subsystem: "dev.chirp.mac", category: "app")
