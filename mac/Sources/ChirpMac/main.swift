import AppKit
import Foundation

let arguments = CommandLine.arguments
if arguments.contains("--selftest") {
    exit(await SelfTest.run(Array(arguments.dropFirst())))
}
// Any other flag is a CLI invocation, never a request to launch the UI (which onboards and asks for TCC grants).
// Launch Services may pass -psn_*; ignore that.
if let flag = arguments.dropFirst().first(where: { $0.hasPrefix("-") && !$0.hasPrefix("-psn_") }) {
    let usage = """
        usage: ChirpMac                         launch the menu-bar app
               ChirpMac --selftest <audio> [--url URL] [--token-file PATH] [--expect WORD] [--fast]
        """
    print(usage)
    exit(flag == "--help" || flag == "-h" ? 0 : 64)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
