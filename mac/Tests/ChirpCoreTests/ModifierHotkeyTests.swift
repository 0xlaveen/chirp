import AppKit
import Carbon.HIToolbox
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Regressions for a modifier-only hotkey (⌥ alone): the recorder, re-registration and the tap being turned off.
@MainActor
@Suite struct ModifierHotkeyTests {
    private let option: UInt64 = 0x80000 | 0x20
    private let cmd = UInt32(cmdKey), opt = UInt32(optionKey)

    /// ⌘ went down in Settings and came up in another app (⌘Tab), so the recorder never saw it let go. Pressing ⌥
    /// alone afterwards records ⌥, not the stale ⌘.
    @Test func aModifierReleaseTheRecorderMissedDoesNotRecordIt() {
        var p = HotkeyRecording.ModifierPress()
        #expect(p.flagsChanged(held: cmd, keyCode: UInt16(kVK_Command)) == nil)
        #expect(p.flagsChanged(held: opt, keyCode: UInt16(kVK_Option)) == nil)
        #expect(p.flagsChanged(held: 0, keyCode: UInt16(kVK_Option)) == .accepted(.option))
        // A key typed during the missed press does not spoil the next one either.
        p.keyDown()
        #expect(p.flagsChanged(held: cmd, keyCode: UInt16(kVK_Command)) == nil)
        #expect(p.flagsChanged(held: opt, keyCode: UInt16(kVK_Option)) == nil)
        #expect(p.flagsChanged(held: 0, keyCode: UInt16(kVK_Option)) == .accepted(.option))
    }

    /// Seen in full, the recorder still keeps the most modifiers held at once, a typed key still spoils it, and a
    /// single right-hand key still records that side.
    @Test func recorderStillRecordsPairsAndSides() {
        var p = HotkeyRecording.ModifierPress()
        _ = p.flagsChanged(held: cmd, keyCode: UInt16(kVK_Command))
        _ = p.flagsChanged(held: cmd | opt, keyCode: UInt16(kVK_Option))
        #expect(p.flagsChanged(held: opt, keyCode: UInt16(kVK_Command)) == nil)
        #expect(p.flagsChanged(held: 0, keyCode: UInt16(kVK_Option)) == .accepted(.custom(keyCode: KeyCombo.anyModifierKey, modifiers: cmd | opt)))

        _ = p.flagsChanged(held: opt, keyCode: UInt16(kVK_Option))
        p.keyDown()
        #expect(p.flagsChanged(held: 0, keyCode: UInt16(kVK_Option)) == nil)

        _ = p.flagsChanged(held: opt, keyCode: UInt16(kVK_RightOption))
        #expect(p.flagsChanged(held: 0, keyCode: UInt16(kVK_RightOption)) == .accepted(.rightOption))
    }

    /// Ending recording makes the owner register the hotkey from settings again, so the new shortcut must be
    /// delivered first; otherwise the old one is registered for a moment and then replaced.
    @Test func aRecordedShortcutArrivesBeforeRecordingEnds() {
        let recorder = HotkeyRecorder()
        var log: [String] = []
        recorder.onRecordingChanged = { log.append($0 ? "start" : "end") }
        recorder.onCapture = { log.append("capture \($0.id)") }
        recorder.start()
        recorder.apply(.accepted(.option))
        #expect(log == ["start", "capture option", "end"])
        #expect(!recorder.isRecording)
    }

    /// Registering the shortcut it already has under the same id keeps the registration (and a press under way) and
    /// only swaps the handlers.
    @Test func registeringTheSameShortcutAgainKeepsThePress() {
        let center = HotKeyCenter.shared
        var log: [String] = []
        center.addTapForTesting(id: 9201, combo: .option, onDown: { log.append("old down") }, onUp: { log.append("old up") })
        defer { center.unregister(id: 9201) }
        center.route(.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: option)).handlers.forEach { $0() }
        #expect(center.register(id: 9201, combo: .option, onDown: { log.append("down") }, onUp: { log.append("up") }))
        center.route(.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: 0)).handlers.forEach { $0() }
        #expect(log == ["old down", "up"])
    }

    /// macOS turned the tap off (`tapDisabledByTimeout`) while ⌥ was down and it missed the release. Turning it back
    /// on catches up with the modifiers held now: the press ends, and the next tap of ⌥ is a tap again.
    @Test func reenablingTheTapEndsAPressWhoseReleaseItMissed() {
        let center = HotKeyCenter.shared
        var log: [String] = []
        center.addTapForTesting(id: 9202, combo: .option, onDown: { log.append("down") }, onUp: { log.append("up") })
        defer { center.unregister(id: 9202) }
        func run(_ e: HotKeyCenter.TapEvent) { center.route(e).handlers.forEach { $0() } }
        run(.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: option))
        run(.resync(cgFlags: 0))   // let go while the tap was off
        run(.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: option))
        run(.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: 0))
        #expect(log == ["down", "up", "down", "up"])
        // Still held when the tap comes back: nothing changes, and a press it missed entirely does not start.
        run(.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: option))
        run(.resync(cgFlags: option))
        run(.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: 0))
        run(.resync(cgFlags: option))
        #expect(log == ["down", "up", "down", "up", "down", "up"])
    }

    /// Without the catch-up the matcher stays pressed, so the next tap's press is lost and its release comes late.
    @Test func withoutTheCatchUpAMissedReleaseSwallowsTheNextTap() {
        var m = ShortcutMatcher(combo: .option)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: option).action == .down)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: option).action == nil)
        #expect(m.resync(cgFlags: 0).action == .up)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: option).action == .down)
    }
}
