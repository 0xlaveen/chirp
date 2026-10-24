import AppKit
import Testing
@testable import ChirpCore
@testable import ChirpUI

@MainActor
@Suite struct PolishTests {
    @Test func manageLocalModelsSaysWhyItIsDisabledForARemoteServer() {
        var s = SettingsState()
        let form = SettingsForm(s)
        func help() -> String? { form.modelsButton.superview?.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.first }
        #expect(form.modelsButton.isEnabled && help()?.hasPrefix("Download") == true)
        s.serverURL = "https://studio.example-tailnet.ts.net"
        form.apply(s, full: true)
        #expect(!form.modelsButton.isEnabled && help()?.hasPrefix("Only for a server on this Mac") == true)
    }

    @Test func theAboutTextDoesNotPromiseAudioStaysOnThisMac() {
        let about = AboutView(icon: nil, info: AboutInfo(version: "1", build: "1"), onNotices: nil)
        func texts(_ v: NSView) -> [String] { v.subviews.flatMap { (($0 as? NSTextField).map { [$0.stringValue] } ?? []) + texts($0) } }
        #expect(!texts(about).joined().contains("never leaves your Mac"))
    }
}
