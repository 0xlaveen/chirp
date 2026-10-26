import AppKit
import ChirpCore
import ChirpUI
import Foundation

let arguments = CommandLine.arguments
switch LaunchMode.parse(Array(arguments.dropFirst())) {
case .selftest:
    exit(await SelfTest.run(Array(arguments.dropFirst())))
case .notesSelftest:
    exit(await NotesSelfTest.run(Array(arguments.dropFirst())))
case .callSelftest:
    exit(await CallAudioSelfTest.run(Array(arguments.dropFirst())))
case .learnSelftest:
    exit(await LearnSelfTest.run(Array(arguments.dropFirst())))
case .renderSnapshots(let directory, let curated):
    // Draws offscreen only: no delegate, no run loop, no onboarding, no permission or pasteboard access.
    do {
        let files = try await MainActor.run {
            // Load the bundle accent before constructing any scenario: native cells cache it on first use.
            _ = NSApplication.shared
            _ = NSColor(named: "AccentColor", bundle: .main)?.usingColorSpace(.sRGB)
            return try Snapshots.render(to: URL(fileURLWithPath: directory, isDirectory: true),
                                        scenarios: curated ? Snapshots.committedScenarios : nil)
        }
        print("Wrote \(files.count) PNGs to \(directory)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("render failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
case .usage(let code):
    // A CLI invocation never launches the UI (which onboards and asks for TCC grants).
    print(LaunchMode.usageText)
    exit(code)
case .app:
    break
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
