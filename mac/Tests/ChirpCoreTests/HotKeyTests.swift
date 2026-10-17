import Carbon.HIToolbox
import Testing
@testable import ChirpCore

@MainActor
@Suite struct HotKeyTests {
    @Test func presetsAreUniqueAndDefaultIsControlOptionSpace() {
        let ids = KeyCombo.presets.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(KeyCombo.presets.first == .controlOptionSpace)
        #expect(KeyCombo.preset(id: "control-shift-space") == .controlShiftSpace)
        #expect(KeyCombo.preset(id: "nonsense") == .controlOptionSpace)
        #expect(KeyCombo.preset(id: nil) == .controlOptionSpace)
    }

    /// macOS 15+ silently ignores Carbon hot keys with only ⌥/⇧ modifiers, and ⌃Space alone belongs to Raycast/input sources.
    @Test func everyPresetCanFireOnCurrentMacOS() {
        for combo in KeyCombo.presets {
            #expect(combo.modifiers & UInt32(controlKey | cmdKey) != 0, "\(combo.title) needs ⌃ or ⌘")
            #expect(combo.modifiers != UInt32(controlKey), "\(combo.title) is ⌃Space alone")
        }
        #expect(KeyCombo.preset(id: "option-space") == .controlOptionSpace)
        #expect(KeyCombo.preset(id: "option-shift-space") == .controlOptionSpace)
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

    /// Press/release timing drives the machine exactly as the Carbon events do: tap toggles, hold is push-to-talk.
    @Test func tapAndHoldThroughDispatch() {
        var machine = DictationMachine()
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

        var hold = DictationMachine()
        clock = 10
        center.addForTesting(id: 9003, onDown: { hold.handle(.hotkeyDown(at: clock)) }, onUp: { hold.handle(.hotkeyUp(at: clock)) })
        defer { center.unregister(id: 9003) }
        center.dispatch(id: 9003, pressed: true)
        clock = 12
        center.dispatch(id: 9003, pressed: false)       // held 2 s → push-to-talk release finalizes
        #expect(hold.state == .finalizing)
    }
}
