import Testing
@testable import ChirpCore

@Suite struct DictationMachineTests {
    @Test func tapTogglesOnAndOff() {
        var m = DictationMachine()
        #expect(m.handle(.hotkeyDown(at: 0)) == [.start])
        #expect(m.state == .connecting)
        #expect(m.handle(.hotkeyUp(at: 0.1)) == [])          // short press: keep recording
        #expect(m.state == .connecting)
        m.handle(.serverReady)
        #expect(m.state == .listening)
        #expect(m.handle(.hotkeyDown(at: 3)) == [.finalize])  // second tap stops
        #expect(m.state == .finalizing)
        #expect(m.handle(.hotkeyUp(at: 3.05)) == [])          // its release is ignored
        #expect(m.state == .finalizing)
    }

    @Test func holdIsPushToTalk() {
        var m = DictationMachine()
        m.handle(.hotkeyDown(at: 10))
        m.handle(.serverReady)
        #expect(m.handle(.hotkeyUp(at: 11.2)) == [.finalize])
        #expect(m.state == .finalizing)
    }

    @Test func holdReleasedBeforeServerReadyStillFinalizes() {
        var m = DictationMachine()
        m.handle(.hotkeyDown(at: 0))
        #expect(m.handle(.hotkeyUp(at: 2)) == [.finalize])
        #expect(m.state == .finalizing)
    }

    @Test func thresholdBoundary() {
        var tap = DictationMachine()
        tap.handle(.hotkeyDown(at: 0))
        #expect(tap.handle(.hotkeyUp(at: 0.299)) == [])
        var hold = DictationMachine()
        hold.handle(.hotkeyDown(at: 0))
        #expect(hold.handle(.hotkeyUp(at: 0.3)) == [.finalize])
    }

    @Test func keyRepeatWhileHeldIsIgnored() {
        var m = DictationMachine()
        m.handle(.hotkeyDown(at: 0))
        #expect(m.handle(.hotkeyDown(at: 0.05)) == [])
        #expect(m.state == .connecting)
    }

    @Test func escapeCancelsInEveryActiveState() {
        for setup in [[], [DictationEvent.serverReady]] {
            var m = DictationMachine()
            m.handle(.hotkeyDown(at: 0))
            m.handle(.hotkeyUp(at: 0.1))
            for e in setup { m.handle(e) }
            #expect(m.handle(.escape) == [.cancel])
            #expect(m.state == .idle)
        }
        var m = DictationMachine()
        m.handle(.hotkeyDown(at: 0)); m.handle(.hotkeyUp(at: 0.1)); m.handle(.serverReady)
        m.handle(.hotkeyDown(at: 1))
        #expect(m.handle(.escape) == [.cancel])      // while finalizing: nothing gets inserted
        #expect(m.handle(.finalReceived) == [])
        #expect(m.state == .idle)
    }

    @Test func escapeWhenIdleDoesNothing() {
        var m = DictationMachine()
        #expect(m.handle(.escape) == [])
        #expect(m.state == .idle)
    }

    @Test func fullHappyPathReturnsToIdle() {
        var m = DictationMachine()
        m.handle(.hotkeyDown(at: 0)); m.handle(.hotkeyUp(at: 0.1)); m.handle(.serverReady)
        m.handle(.hotkeyDown(at: 2))
        #expect(m.handle(.finalReceived) == [.insert])
        #expect(m.state == .inserting)
        m.handle(.insertionFinished)
        #expect(m.state == .idle)
    }

    @Test func failureAbortsAndNextPressRecovers() {
        var m = DictationMachine()
        m.handle(.hotkeyDown(at: 0)); m.handle(.hotkeyUp(at: 0.1))
        #expect(m.handle(.failed("Server unreachable")) == [.abort("Server unreachable")])
        #expect(m.state == .error("Server unreachable"))
        #expect(m.handle(.hotkeyDown(at: 5)) == [.start])
        #expect(m.state == .connecting)
    }

    @Test func staleEventsAreIgnored() {
        var m = DictationMachine()
        #expect(m.handle(.finalReceived) == [])
        #expect(m.handle(.serverReady) == [])
        #expect(m.handle(.hotkeyUp(at: 1)) == [])
        #expect(m.state == .idle)
    }

    @Test func hotkeyIgnoredWhileInserting() {
        var m = DictationMachine()
        m.handle(.hotkeyDown(at: 0)); m.handle(.hotkeyUp(at: 0.1)); m.handle(.serverReady)
        m.handle(.hotkeyDown(at: 1)); m.handle(.finalReceived)
        #expect(m.handle(.hotkeyDown(at: 2)) == [])
        #expect(m.state == .inserting)
    }
}
