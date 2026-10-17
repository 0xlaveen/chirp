import Foundation

public enum MicrophoneAccess: Equatable, Sendable {
    case granted, notAsked, denied
}

/// The server in the words the setup window needs; `Health` and the token file decide it.
public enum ServerCheck: Equatable, Sendable {
    case checking
    case ready(engine: String?)
    case loadingModel
    case unreachable(host: String)
    case noToken

    /// A reachable server wins over a missing token file (a remote server may not need this Mac's token to answer).
    public static func of(tokenPresent: Bool, health: Health?, healthError: String?, host: String) -> ServerCheck {
        if let health { return health.ready == false ? .loadingModel : .ready(engine: health.engine) }
        if !tokenPresent { return .noToken }
        return healthError == nil ? .checking : .unreachable(host: host)
    }
}

/// Live system state the first-run steps display.
public struct OnboardingChecks: Equatable, Sendable {
    public var microphone: MicrophoneAccess = .granted
    public var accessibility = true
    public var server: ServerCheck = .ready(engine: nil)

    public init() {}
}

public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, microphone, accessibility, server, tryIt

    public var title: String {
        switch self {
        case .welcome: "Welcome to Chirp"
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .server: "Speech server"
        case .tryIt: "Try it"
        }
    }
}

/// The first-run window's navigation and rules, free of AppKit. Each permission step reads live state, so a grant made
/// in System Settings turns the step green without a button press. Leaving a step unsatisfied is allowed ("Skip for
/// now"): Chirp still works without Accessibility, copying instead of typing.
///
/// Completion is explicit: `advance(markDone:)` calls `markDone` only when the last step is finished, so closing the
/// window early leaves the flag unset and the setup shows again next launch.
public struct OnboardingFlow: Equatable, Sendable {
    public private(set) var step: OnboardingStep = .welcome
    /// The hotkey was pressed while the Try it step was showing.
    public var heardHotkey = false

    public init() {}

    public var isFirst: Bool { step == .welcome }
    public var isLast: Bool { step == OnboardingStep.allCases.last }
    public var position: (index: Int, count: Int) { (step.rawValue + 1, OnboardingStep.allCases.count) }

    public func isSatisfied(_ step: OnboardingStep, _ checks: OnboardingChecks) -> Bool {
        switch step {
        case .welcome: true
        case .microphone: checks.microphone == .granted
        case .accessibility: checks.accessibility
        case .server: if case .ready = checks.server { true } else { false }
        case .tryIt: heardHotkey
        }
    }

    public func primaryTitle(_ checks: OnboardingChecks) -> String {
        let ok = isSatisfied(step, checks)
        switch step {
        case .welcome: return "Get Started"
        case .tryIt: return ok ? "Done" : "Skip"
        default: return ok ? "Continue" : "Skip for now"
        }
    }

    /// Moves forward; returns true when this finished the flow, after calling `markDone` once.
    @discardableResult
    public mutating func advance(markDone: () -> Void) -> Bool {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            markDone()
            return true
        }
        step = next
        return false
    }

    public mutating func back() {
        if let previous = OnboardingStep(rawValue: step.rawValue - 1) { step = previous }
    }

    /// Re-opening from the menu starts again at the welcome step but keeps nothing else.
    public mutating func restart() { self = OnboardingFlow() }
}
