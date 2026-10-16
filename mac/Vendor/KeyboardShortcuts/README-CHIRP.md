# Vendored KeyboardShortcuts 3.1.0

Upstream: https://github.com/sindresorhus/KeyboardShortcuts (tag 3.1.0, commit 772133d, MIT, see `license`).

Chirp builds with the Command Line Tools only. The CLT toolchain has no SwiftUI/Previews macro plugins, so
upstream fails to build here ("external macro implementation type 'PreviewsMacros.SwiftUIView' / 'SwiftUIMacros.StateMacro'
could not be found"). Local changes, all deletions of SwiftUI-only code Chirp does not use:

- removed `Recorder.swift` (SwiftUI wrapper) and `ViewModifiers.swift`
- removed the `EnvironmentValues`/`View` extensions at the end of `ConflictPolicy.swift`
- removed the DocC catalog and the test target

Chirp uses the AppKit `RecorderCocoa`, the key-down/up handlers and the shortcut storage. To upgrade, copy the new
tag over this directory and repeat the deletions.
