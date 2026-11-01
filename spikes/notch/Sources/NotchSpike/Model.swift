import AppKit
import Observation

struct LevelChoice: Sendable {
    let name: String
    let level: NSWindow.Level
    static let all: [LevelChoice] = [
        .init(name: "normal", level: .normal),
        .init(name: "floating", level: .floating),
        .init(name: "modalPanel", level: .modalPanel),
        .init(name: "mainMenu", level: .mainMenu),
        .init(name: "mainMenu+1", level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)),
        .init(name: "statusBar", level: .statusBar),
        .init(name: "popUpMenu", level: .popUpMenu),
        .init(name: "screenSaver", level: .screenSaver),
        .init(name: "assistiveTechHigh", level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))),
    ]
    static func name(of level: NSWindow.Level) -> String {
        "\(all.first { $0.level == level }?.name ?? "custom")(\(level.rawValue))"
    }
}

struct BehaviourChoice: Sendable, Hashable {
    let name: String
    let flag: NSWindow.CollectionBehavior
    func hash(into h: inout Hasher) { h.combine(name) }
    static func == (a: Self, b: Self) -> Bool { a.name == b.name }
    static let all: [BehaviourChoice] = [
        .init(name: "canJoinAllSpaces", flag: .canJoinAllSpaces),
        .init(name: "fullScreenAuxiliary", flag: .fullScreenAuxiliary),
        .init(name: "stationary", flag: .stationary),
        .init(name: "ignoresCycle", flag: .ignoresCycle),
    ]
    static func names(of b: NSWindow.CollectionBehavior) -> String {
        let n = all.filter { b.contains($0.flag) }.map(\.name)
        return n.isEmpty ? "[]" : "[" + n.joined(separator: ", ") + "]"
    }
}

enum ScreenChoice: Hashable, Sendable {
    case auto            // first screen with a real notch, else primary
    case underMouse
    case index(Int)
}

@MainActor @Observable
final class SpikeModel {
    var state: IslandState = .listening
    var sim: SimNotch = .mbp14
    var levelIndex = LevelChoice.all.firstIndex { $0.name == "statusBar" } ?? 0
    var behaviours: Set<BehaviourChoice> = [BehaviourChoice.all[0], BehaviourChoice.all[1], BehaviourChoice.all[2], BehaviourChoice.all[3]]
    var screenChoice: ScreenChoice = .auto
    var panelVisible = true
    var ignoresMouse = true
    var overlayVisible = true
    var autoCycle = false
    var elapsed = 0

    // Filled in by the controller on every apply().
    var layout = NotchLayout(mode: .floating, notchRect: nil, notchWidth: 0, notchHeight: 0, panelFrame: .zero)
    var diagnostics = ""
    var focusReport = "focus: not checked yet"
    var focusEvents = 0

    var level: LevelChoice { LevelChoice.all[levelIndex] }
}
