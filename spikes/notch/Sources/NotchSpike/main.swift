import AppKit
import SwiftUI

// Usage:
//   swift run NotchSpike                       interactive (status item "Notch" in the menu bar)
//   swift run NotchSpike -- --selftest         scripted checks on this display, exits 0/1
//   swift run NotchSpike -- --snapshots out/   render island PNGs (no window server needed beyond AppKit)
let args = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no app menu: nothing here may activate the app

MainActor.assumeIsolated {
    let c = Controller()
    if let i = args.firstIndex(of: "--snapshots") {
        let dir = args.indices.contains(i + 1) ? args[i + 1] : "out"
        exit(Snapshots.run(into: dir) ? 0 : 1)
    }
    if args.contains("--selftest") {
        app.finishLaunching()
        c.start()
        SelfTest.run(c) // spins the run loop itself, then exits
    } else {
        c.start()
        app.run()
    }
}
