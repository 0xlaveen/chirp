import Carbon.HIToolbox
import Testing
@testable import ChirpCore

@MainActor
@Suite struct HotKeyTests {
    @Test func presetsAreUniqueAndDefaultIsRightOption() {
        let ids = KeyCombo.presets.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(KeyCombo.presets.first == .rightOption && KeyCombo.defaultDictation == .rightOption)
        #expect(KeyCombo.preset(id: "control-shift-space") == .controlShiftSpace)
        #expect(KeyCombo.preset(id: "control-option-space") == .controlOptionSpace)   // still offered
        #expect(KeyCombo.preset(id: "nonsense") == .rightOption)
        #expect(KeyCombo.preset(id: nil) == .rightOption)
    }

    /// Right ⌥ is one physical key, so the left ⌥ (é, ü, ⌥-shortcuts) never reaches it; ⌥ either side and key
    /// combinations are not single keys.
    @Test func onlyAOneSidedModifierIsASingleModifierKey() {
        #expect(KeyCombo.rightOption.isSingleModifierKey)
        #expect(!KeyCombo.option.isSingleModifierKey && !KeyCombo.controlOptionSpace.isSingleModifierKey)
        #expect(!KeyCombo.custom(keyCode: KeyCombo.anyModifierKey, modifiers: ModifierKeys.fn).isSingleModifierKey)
        #expect(KeyCombo.custom(keyCode: UInt32(kVK_RightCommand), modifiers: UInt32(cmdKey)).isSingleModifierKey)
    }

    /// Nothing stored means the user never chose a shortcut, so they follow the default (Right ⌥); anyone who picked
    /// one, ⌃⌥Space included, keeps it.
    @Test func theDefaultFollowsWhoNeverChoseAndKeepsWhoDid() throws {
        let suite = "chirp-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.hotkey == .rightOption && defaults.object(forKey: "hotkey") == nil)   // reading stores nothing
        #expect(prefs[shortcut: .dictation] == .rightOption)
        for chosen in [KeyCombo.controlOptionSpace, .option, .controlShiftSpace, .controlOptionCommandSpace, .rightOption,
                       .custom(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | cmdKey))] {
            prefs.hotkey = chosen
            #expect(Preferences(defaults: defaults).hotkey == chosen)
        }
        // A stored ⌃⌥Space from before the default changed is an explicit choice.
        defaults.set("control-option-space", forKey: "hotkey")
        #expect(prefs.hotkey == .controlOptionSpace)
        defaults.removeObject(forKey: "hotkey")
        #expect(prefs.hotkey == .rightOption)
        // The other shortcuts keep their defaults.
        #expect(prefs.notesHotkey == .controlOptionN && prefs.openNotesHotkey == .controlOptionShiftN)
    }

    @Test func rightOptionNeedsTheEventTapAndIsValidAsRecorded() throws {
        #expect(KeyCombo.rightOption.needsEventTap && KeyCombo.rightOption.isModifierOnly)
        #expect(try HotKeyValidation.validate(keyCode: UInt32(kVK_RightOption), modifiers: UInt32(optionKey)).get() == .rightOption)
        #expect(KeyCombo.rightOption.title == "Right ⌥ Option")
    }

    /// macOS 15+ silently ignores Carbon hot keys with only ⌥/⇧ modifiers, so those come from the event tap; ⌃Space
    /// alone belongs to Raycast/input sources.
    @Test func everyPresetCanFireOnCurrentMacOS() {
        for combo in KeyCombo.presets {
            #expect(combo.needsEventTap || combo.modifiers & UInt32(controlKey | cmdKey) != 0, "\(combo.title) needs ⌃ or ⌘")
            #expect(combo.modifiers != UInt32(controlKey), "\(combo.title) is ⌃Space alone")
            #expect(KeyCombo.resolve(id: combo.id) == combo)
        }
        #expect(KeyCombo.preset(id: "option") == .option && KeyCombo.preset(id: "right-option") == .rightOption)
        // Retired ids fall back to the default.
        #expect(KeyCombo.preset(id: "option-space") == .defaultDictation)
        #expect(KeyCombo.preset(id: "option-shift-space") == .defaultDictation)
    }

    @Test func dispatchRoutesPressAndRelease() {
        var log: [String] = []
        let center = HotKeyCenter.shared
        center.addForTesting(id: 9001, onDown: { log.append("down") }, onUp: { log.append("up") })
        center.dispatch(id: 9001, pressed: true)
        center.dispatch(id: 9001, pressed: false)
        center.dispatch(id: 424242, pressed: true)   // unknown id is ignored
        #expect(log == ["down", "up"])
        center.unregister(id: 9001)
        center.dispatch(id: 9001, pressed: true)
        #expect(log == ["down", "up"])
    }

    /// Press/release timing drives the machine exactly as the Carbon events do: auto-stop toggles on each press,
    /// hold to talk finishes on release.
    @Test func tapAndHoldThroughDispatch() {
        var machine = DictationMachine(mode: .autoStop)
        var clock: TimeInterval = 0
        let center = HotKeyCenter.shared
        center.addForTesting(id: 9002, onDown: { machine.handle(.hotkeyDown(at: clock)) }, onUp: { machine.handle(.hotkeyUp(at: clock)) })
        defer { center.unregister(id: 9002) }

        center.dispatch(id: 9002, pressed: true)
        clock = 0.1
        center.dispatch(id: 9002, pressed: false)       // tap → still recording
        #expect(machine.state == .connecting)
        clock = 5
        center.dispatch(id: 9002, pressed: true)        // second tap stops
        #expect(machine.state == .finalizing)
        clock = 5.05
        center.dispatch(id: 9002, pressed: false)

        var hold = DictationMachine(mode: .holdToTalk)
        clock = 10
        center.addForTesting(id: 9003, onDown: { hold.handle(.hotkeyDown(at: clock)) }, onUp: { hold.handle(.hotkeyUp(at: clock)) })
        defer { center.unregister(id: 9003) }
        center.dispatch(id: 9003, pressed: true)
        clock = 12
        center.dispatch(id: 9003, pressed: false)       // held 2 s → push-to-talk release finalizes
        #expect(hold.state == .finalizing)
    }
}
