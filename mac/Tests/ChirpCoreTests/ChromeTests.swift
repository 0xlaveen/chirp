import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// The Pond chrome: the onboarding step rail and welcome, the HUD's fixed-width panel and the export-folder preference.
@MainActor
@Suite struct ChromeTests {
    private func checks(mic: MicrophoneAccess = .granted, ax: Bool = true, server: ServerCheck = .ready(engine: nil)) -> OnboardingChecks {
        var c = OnboardingChecks()
        c.microphone = mic; c.accessibility = ax; c.server = server
        return c
    }

    // MARK: onboarding rail

    @Test func railMarksTheCurrentStepAndWhatIsAheadLive() {
        let welcome = OnboardingRail.marks(OnboardingFlow(), checks())
        #expect(welcome == [.current, .done, .done, .done, .upcoming])   // checks that already pass show ✓ ahead of time
        let blocked = OnboardingRail.marks(OnboardingFlow(), checks(mic: .denied, ax: false, server: .unreachable(host: "h")))
        #expect(blocked == [.current, .upcoming, .upcoming, .upcoming, .upcoming])
    }

    @Test func railTurnsAPassedStepWarningWhenItIsNotInOrder() {
        let flow = OnboardingState(step: .server).flow
        let ok = OnboardingRail.marks(flow, checks())
        #expect(ok == [.done, .done, .done, .current, .upcoming])
        let revoked = OnboardingRail.marks(flow, checks(mic: .denied, ax: false))
        #expect(revoked == [.done, .warning, .warning, .current, .upcoming])
        let last = OnboardingState(step: .tryIt, heardHotkey: true).flow
        #expect(OnboardingRail.marks(last, checks()) == [.done, .done, .done, .done, .current])
    }

    @Test func railRowsAreLabelledForVoiceOver() {
        #expect(OnboardingRail.label(.microphone, .done) == "Microphone, done")
        #expect(OnboardingRail.label(.accessibility, .warning) == "Accessibility, needs attention")
        #expect(OnboardingRail.label(.tryIt, .current) == "Try it, current step")
        #expect(OnboardingRail.label(.server, .upcoming) == "Chirp server")
    }

    @Test func keycapsSplitAShortcutIntoItsKeys() {
        #expect(OnboardingView.keySymbols("⌃⌥Space") == ["⌃", "⌥", "Space"])
        #expect(OnboardingView.keySymbols("⌃⌥⇧N") == ["⌃", "⌥", "⇧", "N"])
        #expect(OnboardingView.keySymbols("⌥") == ["⌥"])
        // A modifier on its own is one keycap, named for its side.
        #expect(OnboardingView.keySymbols("Right ⌥ Option") == ["Right ⌥ Option"])
        #expect(OnboardingView.keySymbols("⌥ Option") == ["⌥ Option"])
    }

    @Test func theWelcomeIntroducesDictationAndNotesAndTheLastStepOffersOpenNotes() {
        let view = OnboardingView(icon: nil, pond: nil)
        view.apply(OnboardingState(step: .welcome))
        func texts(_ v: NSView) -> [String] {
            ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts)
        }
        let welcome = texts(view)
        #expect(welcome.contains("Dictate into any app"))
        #expect(welcome.contains("Keep conversations in Notes"))
        #expect(view.primary.title == "Get Started" && view.openNotes.isHidden)
        view.apply(OnboardingState(step: .tryIt, heardHotkey: true))
        #expect(!view.openNotes.isHidden && view.openNotes.title == "Open Notes")
        #expect(view.primary.title == "Done")
        #expect(OnboardingView.size == NSSize(width: 720, height: 460))
    }

    // MARK: HUD

    @Test func hudPanelWidthIsFixedPerMode() {
        let model = HUDModel()
        for words in [false, true] {
            model.wordWaveform = words
            let view = NSHostingViewForTests.host(HUDView(model: model))
            for text in ["", "short", String(repeating: "a long dictation goes on ", count: 12)] {
                model.stable = text
                view.layoutSubtreeIfNeeded()
                #expect(abs(view.fittingSize.width - HUDViewMetrics.width(wordWaveform: words)) < 0.5, "\(words) \(text.count)")
            }
        }
    }

    @Test func hudTranscriptStaysWithinThreeLines() {
        let model = HUDModel()
        model.flatSurface = true
        model.stable = String(repeating: "word ", count: 80)
        let view = NSHostingViewForTests.host(HUDView(model: model))
        view.layoutSubtreeIfNeeded()
        // 3 lines of 15 pt text plus the header row and the padding: well under four lines' worth.
        let limit: CGFloat = 3 * 20 + 44 + 24 + 4
        #expect(view.fittingSize.height < limit)
        let kept = HUDText.tail(stable: model.stable, unstable: "", limit: HUDText.lineBudget).stable.count
        #expect(kept <= HUDText.lineBudget + 2)
    }

    // MARK: export folder

    @Test func exportFolderIsAPathThatClearsBackToNone() {
        let name = "chirp-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.notesExportFolder == nil)
        prefs.notesExportFolder = "/tmp/notes"
        #expect(Preferences(defaults: defaults).notesExportFolder == "/tmp/notes")
        prefs.notesExportFolder = nil
        #expect(Preferences(defaults: defaults).notesExportFolder == nil)
    }
}

@MainActor
private enum NSHostingViewForTests {
    static func host<V: SwiftUI.View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)
        return host
    }
}
