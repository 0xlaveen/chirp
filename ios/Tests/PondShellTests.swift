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

    @Test func recentlyDeletedCountdownIsSingularForOneDay() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        func left(daysAgo: Double) -> String { RecentlyDeletedCopy.daysLeft(since: now.addingTimeInterval(-daysAgo * 86400), now: now) }
        #expect(left(daysAgo: 29) == "1 day left")
        #expect(left(daysAgo: 28) == "2 days left")
        #expect(left(daysAgo: 0) == "30 days left")
        #expect(left(daysAgo: 30) == "0 days left")
        #expect(left(daysAgo: 45) == "0 days left")
    }

    @Test func settingsSummariesFollowTheirSwitch() {
        #expect(SettingsSummary.spokenCommands(on: false) == "Off by default")
        #expect(SettingsSummary.spokenCommands(on: true) == "On")
        #expect(SettingsSummary.history(on: false).hasPrefix("Off by default"))
        #expect(SettingsSummary.history(on: true).hasPrefix("On ·"))
        #expect(!SettingsSummary.history(on: true).contains("Off"))
        #expect(SettingsSummary.pause(on: false) == "Off")
        #expect(SettingsSummary.pause(on: true).hasPrefix("Paused"))
    }

    /// Note rows and the detail meta line say the same as Android and the Mac (#271 2.4, 2.8).
    @Test func noteMetaMatchesTheOtherPlatforms() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        func age(_ seconds: Double) -> String { NoteMeta.age(since: now.addingTimeInterval(-seconds), now: now) }
        #expect(age(20) == "Just now")
        #expect(age(5 * 60) == "5 min ago")
        #expect(age(3 * 3600) == "3 h ago")
        #expect(age(30 * 3600) == "Yesterday")
        #expect(age(4 * 86400) == "4 days ago")
        #expect(age(-60) == "Just now", "a clock that moved back never shows a negative age")
        #expect(NoteMeta.duration(0.4) == nil)
        #expect(NoteMeta.duration(45) == "45 sec")
        #expect(NoteMeta.duration(192) == "3 min")
        let facts = NoteMeta.facts(created: now, duration: 192, openTodos: 2, audioBytes: 640_000)
        let parts = facts.components(separatedBy: " · ")
        #expect(parts.count == 4)
        #expect(parts[0] == now.formatted(date: .abbreviated, time: .shortened))
        #expect(Array(parts[1...2]) == ["3 min", "☐ 2 open"])
        #expect(NoteMeta.facts(created: now, duration: nil, openTodos: 0, audioBytes: 0) == now.formatted(date: .abbreviated, time: .shortened))
        #expect(NoteMeta.untitled == "Untitled note")
    }
}
