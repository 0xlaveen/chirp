import ChirpIOSCore
import Foundation
import Testing
@testable import ChirpIOS

/// The app shell's small decisions (#192): which setup step comes next, what the connection chip says, the timers.
@Suite("Pond shell")
struct PondShellTests {
    @Test func setupNamesTheFirstMissingStepInOrder() {
        #expect(SetupProgress(paired: false, microphone: false, keyboard: false).firstMissing == .pair)
        #expect(SetupProgress(paired: false, microphone: true, keyboard: true).firstMissing == .pair)
        #expect(SetupProgress(paired: true, microphone: false, keyboard: true).firstMissing == .microphone)
        #expect(SetupProgress(paired: true, microphone: true, keyboard: false).firstMissing == .keyboard)
        let done = SetupProgress(paired: true, microphone: true, keyboard: true)
        #expect(done.firstMissing == nil && done.isComplete)
        #expect(SetupProgress.Step.allCases.map(SetupProgress.fix) == ["Pair computer", "Allow", "Open Settings"])
    }

    @Test func connectionChipFollowsPairingAndReachability() {
        #expect(ConnectionChip.status(paired: false, issue: nil) == ("Not paired", false))
        #expect(ConnectionChip.status(paired: false, issue: .offline) == ("Not paired", false))
        #expect(ConnectionChip.status(paired: true, issue: nil) == ("Computer", true))
        for issue in ConnectionIssue.allCases {
            #expect(ConnectionChip.status(paired: true, issue: issue) == ("Offline", false), "\(issue)")
        }
    }

    @Test func timersUseMinutesAndSeconds() {
        #expect(DictateView.clock(0) == "0:00")
        #expect(DictateView.clock(7.9) == "0:07")
        #expect(DictateView.clock(252) == "4:12")
        #expect(DictateView.clock(3_600) == "60:00")
        #expect(DictateView.clock(-3) == "0:00", "a passed deadline never shows negative time")
    }

    @Test func onboardingTitlesMatchTheAndroidWizard() {
        #expect(OnboardingCopy.welcome == "Welcome to Chirp")
        #expect(OnboardingCopy.pair == "Pair your computer")
        #expect(OnboardingCopy.aboutPairing == "About pairing")
        #expect(OnboardingCopy.microphone == "Allow the microphone")
        #expect(OnboardingCopy.aboutMicrophone == "What Chirp keeps")
        #expect(OnboardingCopy.keyboard == "Turn on Chirp Keyboard")
        #expect(OnboardingCopy.aboutKeyboard == "About the keyboard")
        #expect(OnboardingCopy.pairingSteps == "On your computer, open Chirp → Settings → Devices → Pair a Phone, or run chirp-server pair on your server.")
        #expect(!OnboardingCopy.pairingSteps.contains("Mac"))
    }

    @Test func tabsAreTheFourDestinationsInShortcutOrder() {
        #expect(ChirpTab.allCases == [.notes, .dictate, .history, .settings])
        #expect(ChirpTab.allCases.map(\.title) == ["Notes", "Dictate", "History", "Settings"])
        #expect(ChirpTab(rawValue: "notes") == .notes, "SceneStorage restores the tab by its raw value")
    }
}
