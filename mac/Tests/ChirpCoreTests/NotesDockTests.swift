import Carbon.HIToolbox
import Foundation
import Testing
@testable import ChirpCore

@Suite struct DockPresenceTests {
    @Test func menuBarOnlyUntilANotesWindowOpens() {
        var d = DockPresence()
        #expect(d.policy == .accessory)
        d.windowShown()
        #expect(d.policy == .regular)
        d.windowClosed()
        #expect(d.policy == .accessory)
    }

    @Test func theLastWindowClosingGivesTheDockBack() {
        var d = DockPresence()
        d.windowShown()
        d.windowShown()
        d.windowClosed()
        #expect(d.policy == .regular)
        d.windowClosed()
        #expect(d.policy == .accessory)
        d.windowClosed()   // a stray close never goes below zero
        d.windowShown()
        #expect(d.policy == .regular)
    }

    @Test func aWindowHiddenWhileRecordingKeepsTheDockSoItCanBeFound() {
        var d = DockPresence()
        d.recordingChanged(true)
        d.windowShown()
        d.windowHidden()   // Close while recording only hides
        #expect(d.policy == .regular)
        d.windowShown()    // the Dock click brings it back
        #expect(d.policy == .regular && d.hidden == 0)
        d.windowHidden()
        d.recordingChanged(false)   // recording ended behind the hidden window
        #expect(d.policy == .accessory)
        d.recordingChanged(true)
        #expect(d.policy == .regular)
        d.windowClosed(wasHidden: true)
        #expect(d.policy == .accessory)
    }

    @Test func aHiddenWindowWithNothingRecordingDoesNotHoldTheDock() {
        var d = DockPresence()
        d.windowShown()
        d.windowHidden()
        #expect(d.policy == .accessory)
    }

    @Test func alwaysShowKeepsTheDockWithNoWindow() {
        var d = DockPresence(alwaysShow: true)
        #expect(d.policy == .regular)
        d.windowShown()
        d.windowClosed()
        #expect(d.policy == .regular)
        d.alwaysShow = false
        #expect(d.policy == .accessory)
    }

    @Test func aMinimisedWindowStaysInTheDock() {
        // Minimising neither shows nor hides: the window is still counted as shown.
        var d = DockPresence()
        d.windowShown()
        #expect(d.policy == .regular && d.shown == 1)
    }
}

@Suite struct NotesHotkeyRouterTests {
    private func route(front: Bool, dictating: Bool = false, _ state: NotesRecorderState, pause: Bool = false) -> NotesHotkeyRouter.Route {
        NotesHotkeyRouter.route(notesFrontmost: front, dictationActive: dictating, notes: state, pauseAvailable: pause)
    }

    @Test func outsideTheNotesWindowTheHotkeyDictates() {
        for state in [NotesRecorderState.idle, .recording, .stopped, .stopping] {
            #expect(route(front: false, state) == .dictate)
        }
    }

    @Test func inTheNotesWindowTheFirstPressRecords() {
        for state in [NotesRecorderState.idle, .stopped, .error("x")] {
            #expect(route(front: true, state) == .notes(.start))
        }
    }

    @Test func aLaterPressStopsWithoutPauseAndPausesOrResumesWithIt() {
        #expect(route(front: true, .recording) == .notes(.stop))
        #expect(route(front: true, .starting) == .notes(.stop))
        #expect(route(front: true, .recording, pause: true) == .notes(.togglePause))
        #expect(route(front: true, .paused, pause: true) == .notes(.togglePause))
        #expect(route(front: true, .starting, pause: true) == .notes(.ignore))
        #expect(NotesHotkeyRouter.pauseAvailable)
    }

    @Test func finishingSwallowsThePressRatherThanDictating() {
        #expect(route(front: true, .stopping) == .notes(.ignore))
    }

    @Test func aRunningDictationKeepsItsOwnHotkey() {
        #expect(route(front: true, dictating: true, .idle) == .dictate)
    }
}

@Suite struct OpenNotesShortcutTests {
    private let taken: [(owner: String, combo: KeyCombo)] = [("dictation", .controlOptionSpace), ("Start/Stop Notes", .controlOptionN)]

    @Test func theDefaultIsFreeAndDistinct() {
        #expect(HotKeyValidation.conflict(.controlOptionShiftN, with: taken) == nil)
        #expect(KeyCombo.controlOptionShiftN.title == "⌃⌥⇧N")
        #expect(!KeyCombo.controlOptionShiftN.needsEventTap)   // a Carbon hot key, no Accessibility needed
    }

    @Test func anotherChirpShortcutIsRefusedWithItsName() {
        #expect(HotKeyValidation.conflict(.controlOptionN, with: taken) == .inUse("Start/Stop Notes"))
        #expect(HotKeyValidation.conflict(.controlOptionSpace, with: taken) == .inUse("dictation"))
        #expect(HotKeyValidation.Rejection.inUse("dictation").reason.contains("dictation"))
    }

    @Test func aRecordedShortcutStillGoesThroughTheUsualRules() throws {
        #expect(HotKeyValidation.validate(keyCode: UInt32(kVK_ANSI_N), modifiers: 0) == .failure(.noModifier))
        let combo = try HotKeyValidation.validate(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(controlKey | optionKey)).get()
        #expect(HotKeyValidation.conflict(combo, with: taken) == nil)
    }

    @Test func preferencesKeepItAndFallBackToTheDefault() throws {
        let suite = "chirp-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.openNotesHotkey == .controlOptionShiftN && !prefs.alwaysShowInDock)
        let custom = try HotKeyValidation.validate(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(controlKey | optionKey)).get()
        prefs.openNotesHotkey = custom
        prefs.alwaysShowInDock = true
        let again = Preferences(defaults: defaults)
        #expect(again.openNotesHotkey == custom && again.alwaysShowInDock)
        defaults.set("custom:\(kVK_ANSI_N):0", forKey: "openNotesHotkey")   // a key that cannot fire
        defaults.set("bogus", forKey: "openNotesHotkey")
        #expect(prefs.openNotesHotkey == .controlOptionShiftN)
        // The dictation hotkey's own fallback is unchanged.
        defaults.set("bogus", forKey: "hotkey")
        #expect(prefs.hotkey == .controlOptionSpace)
    }
}
