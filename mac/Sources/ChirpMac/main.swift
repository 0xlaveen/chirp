import AppKit
import ChirpCore
import Foundation

let arguments = CommandLine.arguments
switch LaunchMode.parse(Array(arguments.dropFirst())) {
case .selftest:
    exit(await SelfTest.run(Array(arguments.dropFirst())))
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
