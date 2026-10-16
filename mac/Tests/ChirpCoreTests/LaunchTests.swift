import Testing
@testable import ChirpCore

@Suite struct LaunchModeTests {
    @Test func bareLaunchStartsTheApp() {
        #expect(LaunchMode.parse([]) == .app)
        #expect(LaunchMode.parse(["-psn_0_12345"]) == .app)
    }

    @Test func anyCLIFlagPrintsUsageAndNeverLaunchesUI() {
        #expect(LaunchMode.parse(["--help"]) == .usage(exitCode: 0))
        #expect(LaunchMode.parse(["-h"]) == .usage(exitCode: 0))
        #expect(LaunchMode.parse(["--version"]) == .usage(exitCode: 64))
        #expect(LaunchMode.parse(["--bogus", "x"]) == .usage(exitCode: 64))
        #expect(LaunchMode.parse(["-psn_0_1", "--help"]) == .usage(exitCode: 0))
        #expect(LaunchMode.parse(["stray-positional"]) == .usage(exitCode: 64))
    }

    @Test func selftestIsRecognisedAnywhere() {
        #expect(LaunchMode.parse(["--selftest", "a.wav"]) == .selftest)
        #expect(LaunchMode.parse(["--fast", "--selftest", "a.wav"]) == .selftest)
    }
}

@MainActor
@Suite struct OnboardingTests {
    final class Log { var calls: [String] = []; var done = false }

    private func onboarding(_ log: Log, axGranted: Bool = false, mic: @escaping () async -> Bool = { true }) -> Onboarding {
        Onboarding(
            isDone: { log.done }, markDone: { log.calls.append("done"); log.done = true },
            requestMicrophone: { log.calls.append("mic"); return await mic() },
            accessibilityGranted: { axGranted },
            promptAccessibility: { log.calls.append("ax") })
    }

    @Test func marksDoneOnlyAfterBothPrompts() async {
        let log = Log()
        #expect(await onboarding(log).runIfNeeded())
        #expect(log.calls == ["mic", "ax", "done"])
    }

    @Test func skipsAccessibilityPromptWhenTrusted() async {
        let log = Log()
        await onboarding(log, axGranted: true).runIfNeeded()
        #expect(log.calls == ["mic", "done"])
    }

    @Test func doesNothingOnceDone() async {
        let log = Log()
        log.done = true
        #expect(await onboarding(log).runIfNeeded() == false)
        #expect(log.calls.isEmpty)
    }

    @Test func interruptedOnboardingIsNotMarkedDone() async {
        let log = Log()
        let task = Task { @MainActor in
            await onboarding(log, mic: {
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            }).runIfNeeded()
        }
        _ = await task.value
        #expect(log.calls == ["mic"])
        #expect(log.done == false)
    }
}
