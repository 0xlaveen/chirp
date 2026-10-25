import AppKit
import Testing
@testable import ChirpCore
@testable import ChirpUI

@MainActor
@Suite struct PolishTests {
    @Test func manageLocalModelsSaysWhyItIsDisabledForARemoteServer() {
        var s = SettingsState()
        let form = SettingsForm(s)
        func help() -> String? {
            form.view(for: .advanced).allDescendants(of: SettingsRow.self).first { $0.allDescendants(of: NSButton.self).contains(form.modelsButton) }?
                .allDescendants(of: NSTextField.self).last?.stringValue
        }
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

@MainActor
@Suite struct FollowupTests {
    @Test func anUnreachableServerSaysWhichAddressAndWhatToTry() {
        var s = SettingsState()
        s.serverStatus = "Unreachable"; s.serverStatusTone = .error
        let local = SettingsForm.unreachableHelp(serverURL: "ws://127.0.0.1:7821/v1/stream")
        #expect(local.contains("127.0.0.1:7821") && local.contains("Manage Local Models") && local.contains("Doctor"))
        let remote = SettingsForm.unreachableHelp(serverURL: "https://studio.example-tailnet.ts.net/chirp")
        #expect(remote.contains("studio.example-tailnet.ts.net") && remote.contains("tailnet"))
        let form = SettingsForm(s)
        func texts(_ v: NSView) -> [String] { v.subviews.flatMap { (($0 as? NSTextField).map { [$0.stringValue] } ?? []) + texts($0) } }
        #expect(texts(form.view(for: .advanced)).contains { $0.hasPrefix("Nothing answers at") })
        s.serverStatus = "Connected"; s.serverStatusTone = .ok
        form.apply(s, full: true)
        #expect(!texts(form.view(for: .advanced)).contains { $0.hasPrefix("Nothing answers at") })
    }

    @Test func serverAndTokenErrorsOfferServerSettings() {
        #expect(NotesStatus.errorOpensServerSettings("Notes stopped: Server rejected the token"))
        #expect(NotesStatus.errorOpensServerSettings("Server unreachable at 127.0.0.1"))
        #expect(!NotesStatus.errorOpensServerSettings("The microphone stopped — check the input device"))
        #expect(!NotesStatus.errorOpensServerSettings("Notes stopped: Server is busy"))
    }

    @Test func theDebugWarningSaysHowToEndIt() {
        var m = MenuInputs()
        m.health = Health(ok: true, engine: "e", ready: true, debugRetention: true)
        m.debugRetention = true
        let header = MenuContent.header(m)
        #expect(header.status == MenuContent.debugRetention && header.help?.contains("retain = true") == true)
        #expect(MenuContent.header(MenuInputs()).help == nil)
    }
}
