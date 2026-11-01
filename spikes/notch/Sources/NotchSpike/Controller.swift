import AppKit
import SwiftUI

nonisolated(unsafe) var quiet = false
func say(_ s: String) { if !quiet { print(s); fflush(stdout) } }
func report(_ s: String) { print(s); fflush(stdout) }

@MainActor
final class Controller: NSObject, NSMenuItemValidation {
    let model = SpikeModel()
    var panel: IslandPanel!
    var overlay: IslandPanel!
    var statusItem: NSStatusItem!
    var timer: Timer?
    var autoTimer: Timer?
    var frontmostBefore: String?
    var observers: [NSObjectProtocol] = []

    func start() {
        panel = makePanel(size: NotchGeometry.panelSize, content: PanelContent(model: model))
        overlay = makePanel(size: CGSize(width: 780, height: 330), content: OverlayView(model: model))
        overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Notch"
        rebuildMenu()
        installObservers()
        installGlobalHotkeys()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.model.state == .listening { self?.model.elapsed += 1 } }
        }
        apply(reason: "launch")
    }

    // MARK: screens

    func targetScreen() -> NSScreen? {
        let all = NSScreen.screens
        switch model.screenChoice {
        case .auto: return all.first { $0.safeAreaInsets.top > 0 } ?? all.first
        case .underMouse: return all.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? all.first
        case .index(let i): return all.indices.contains(i) ? all[i] : all.first
        }
    }

    // MARK: apply

    /// Re-reads the screen, recomputes the layout, pushes level / behaviour / frame to the panel and logs everything.
    func apply(reason: String, orderFront: Bool = true) {
        guard let screen = targetScreen() else { say("no screens"); return }
        let real = ScreenMetrics(screen)
        let metrics = (model.sim != .off && !real.hasRealNotch) ? ScreenMetrics.fake(model.sim, on: real) : real
        model.layout = NotchGeometry.layout(metrics)

        frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        panel.level = model.level.level
        panel.collectionBehavior = model.behaviours.reduce(into: []) { $0.formUnion($1.flag) }
        panel.ignoresMouseEvents = model.ignoresMouse
        panel.setFrame(model.layout.panelFrame, display: true)
        if orderFront && model.panelVisible { panel.orderFrontRegardless() } else if !model.panelVisible { panel.orderOut(nil) }

        // overlay: bottom-left of the target screen
        overlay.setFrame(CGRect(x: screen.frame.minX + 12, y: screen.frame.minY + 12, width: 780, height: 330), display: true)
        overlay.ignoresMouseEvents = true
        if model.overlayVisible { overlay.orderFrontRegardless() } else { overlay.orderOut(nil) }

        // Let AppKit settle, then judge focus and frame drift.
        let work = { [weak self] in
            guard let self else { return }
            self.refreshDiagnostics(reason: reason, screen: screen, metrics: metrics)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated(work) }
    }

    func refreshDiagnostics(reason: String, screen: NSScreen, metrics: ScreenMetrics) {
        var lines = ["=== NotchSpike [\(reason)] mode=\(model.layout.mode.rawValue) sim=\(model.sim == .off ? "off" : "on") state=\(model.state.rawValue) macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        for (i, s) in NSScreen.screens.enumerated() {
            let m = ScreenMetrics(s)
            let ins = s.safeAreaInsets
            lines.append("screen[\(i)]\(s == screen ? "*" : "") \"\(s.localizedName)\" scale=\(s.backingScaleFactor)")
            lines.append("  frame=\(fmt(m.frame)) visibleFrame=\(fmt(m.visibleFrame)) menuBarH=\(f(m.menuBarHeight))")
            lines.append("  safeAreaInsets=(t:\(f(ins.top)) l:\(f(ins.left)) b:\(f(ins.bottom)) r:\(f(ins.right))) auxL=\(m.auxLeft.map(fmt) ?? "nil") auxR=\(m.auxRight.map(fmt) ?? "nil")")
            if m.hasRealNotch, let l = m.auxLeft, let r = m.auxRight { lines.append("  REAL NOTCH width=\(f(r.minX - l.maxX)) height=\(f(m.safeAreaTop))") }
        }
        if metrics != ScreenMetrics(screen) { lines.append("  (layout uses SIMULATED metrics: safeTop=\(f(metrics.safeAreaTop)) notchW=\(f(model.layout.notchWidth)))") }
        let drift = panel.frame != model.layout.panelFrame
        let frontNow = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ours = Bundle.main.bundleIdentifier
        let stole = panel.isKeyWindow || panel.isMainWindow || (frontNow != frontmostBefore && frontNow == ours)
        lines.append("panel: level=\(LevelChoice.name(of: panel.level)) collection=\(BehaviourChoice.names(of: panel.collectionBehavior))")
        lines.append("  frame=\(fmt(panel.frame)) expected=\(fmt(model.layout.panelFrame)) frameDrift=\(drift ? "YES (AppKit moved it)" : "no") onScreen=\(panel.isVisible) occluded=\(!panel.occlusionState.contains(.visible)) activeSpace=\(panel.isOnActiveSpace)")
        lines.append("  isKey=\(panel.isKeyWindow) isMain=\(panel.isMainWindow) appActive=\(NSApp.isActive) frontmost=\(frontNow ?? "nil") (before: \(frontmostBefore ?? "nil")) STOLE_FOCUS=\(stole) constrainCalls=\(panel.constrainCalls) ignoresMouse=\(panel.ignoresMouseEvents)")
        model.diagnostics = lines.joined(separator: "\n")
        model.focusReport = "focusEvents=\(model.focusEvents) lastCheck: \(stole ? "STOLE FOCUS" : "no focus theft") | hotkeys: \(AXIsProcessTrusted() ? "global ok" : "menu only (no Accessibility)")"
        lastStole = stole; lastDrift = drift
        say(lines.joined(separator: "\n"))
    }
    var lastStole = false, lastDrift = false

    func f(_ v: CGFloat) -> String { String(format: "%g", Double(v)) }
    func fmt(_ r: CGRect) -> String { "(\(f(r.minX)),\(f(r.minY)) \(f(r.width))x\(f(r.height)))" }

    // MARK: observers

    func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { say(">> screen parameters changed (display attach/detach, clamshell, resolution)"); self?.apply(reason: "screen-params-changed") }
        })
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.focusEvents += 1; say(">> !! PANEL BECAME KEY") }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.focusEvents += 1; say(">> app became active (menu interaction is expected; otherwise it is focus theft)") }
        })
        let wnc = NSWorkspace.shared.notificationCenter
        observers.append(wnc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { say(">> frontmost app now: \(app?.localizedName ?? "?") (\(app?.bundleIdentifier ?? "?"))") }
        })
        observers.append(wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { say(">> active Space changed"); self?.apply(reason: "space-changed") }
        })
    }

    /// Ctrl+Opt+1/2/3 state, L level, B behaviours, D display, S sim, H overlay. Needs Accessibility; the menu always works.
    func installGlobalHotkeys() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.modifierFlags.intersection([.control, .option, .command, .shift]) == [.control, .option] else { return }
            let ch = e.charactersIgnoringModifiers ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                switch ch {
                case "1": self.setState(.listening)
                case "2": self.setState(.polishing)
                case "3": self.setState(.done)
                case "l": self.cycleLevel()
                case "d": self.cycleScreen()
                case "s": self.cycleSim()
                case "h": self.toggleOverlay()
                case "v": self.toggleVisible()
                default: break
                }
            }
        }
    }

    // MARK: actions

    func setState(_ s: IslandState) {
        if s == .listening { model.elapsed = 0 }
        model.state = s; apply(reason: "state=\(s.rawValue)"); rebuildMenu()
    }
    func cycleLevel() { model.levelIndex = (model.levelIndex + 1) % LevelChoice.all.count; apply(reason: "level"); rebuildMenu() }
    func cycleScreen() {
        let n = NSScreen.screens.count
        let cur: Int = { if case .index(let i) = model.screenChoice { return i }; return -1 }()
        model.screenChoice = .index((cur + 1) % max(n, 1)); apply(reason: "display"); rebuildMenu()
    }
    func cycleSim() {
        let all = SimNotch.allCases; model.sim = all[(all.firstIndex(of: model.sim)! + 1) % all.count]; apply(reason: "sim"); rebuildMenu()
    }
    func toggleOverlay() { model.overlayVisible.toggle(); apply(reason: "overlay"); rebuildMenu() }
    func toggleVisible() { model.panelVisible.toggle(); apply(reason: "visibility"); rebuildMenu() }
    func toggleAuto() {
        model.autoCycle.toggle()
        autoTimer?.invalidate()
        if model.autoCycle {
            autoTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let all = IslandState.allCases
                    self.setState(all[(all.firstIndex(of: self.model.state)! + 1) % all.count])
                }
            }
        }
        rebuildMenu()
    }
    func delayedApply(seconds: Double) {
        say(">> will re-show the panel in \(seconds)s: switch to another app/Space/full-screen window NOW")
        model.panelVisible = false; apply(reason: "hidden-for-delay")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            model.panelVisible = true; apply(reason: "delayed-show")
        }
        rebuildMenu()
    }

    // MARK: menu

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }

    func item(_ title: String, key: String = "", checked: Bool = false, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let it = ClosureItem(title: title, key: key, action: action)
        it.state = checked ? .on : .off
        return it
    }

    func rebuildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "State (hotkey: ctrl+opt+1/2/3)", action: nil, keyEquivalent: "").isEnabled = false
        for (i, s) in IslandState.allCases.enumerated() {
            m.addItem(item(s.rawValue.capitalized, key: "\(i + 1)", checked: model.state == s) { [self] in setState(s) })
        }
        m.addItem(.separator())
        m.addItem(item("Panel visible", key: "v", checked: model.panelVisible) { [self] in toggleVisible() })
        m.addItem(item("Click-through (ignoresMouseEvents)", checked: model.ignoresMouse) { [self] in model.ignoresMouse.toggle(); apply(reason: "ignoresMouse"); rebuildMenu() })
        m.addItem(item("Let AppKit constrain the frame (default behaviour)", checked: panel.allowConstrain) { [self] in panel.allowConstrain.toggle(); apply(reason: "constrain=\(panel.allowConstrain)"); rebuildMenu() })
        m.addItem(item("Auto-cycle states every 2.5s", checked: model.autoCycle) { [self] in toggleAuto() })
        m.addItem(item("Hide, then re-show in 8s (switch app/Space/full screen meanwhile)") { [self] in delayedApply(seconds: 8) })
        m.addItem(.separator())

        let lv = NSMenu()
        for (i, l) in LevelChoice.all.enumerated() {
            lv.addItem(item("\(l.name) (\(l.level.rawValue))", checked: model.levelIndex == i) { [self] in model.levelIndex = i; apply(reason: "level=\(l.name)"); rebuildMenu() })
        }
        let lvItem = NSMenuItem(title: "Window level: \(model.level.name)  (ctrl+opt+L cycles)", action: nil, keyEquivalent: ""); lvItem.submenu = lv
        m.addItem(lvItem)

        let bh = NSMenu()
        for b in BehaviourChoice.all {
            bh.addItem(item(b.name, checked: model.behaviours.contains(b)) { [self] in
                if model.behaviours.contains(b) { model.behaviours.remove(b) } else { model.behaviours.insert(b) }
                apply(reason: "behaviour"); rebuildMenu()
            })
        }
        let bhItem = NSMenuItem(title: "Collection behaviour", action: nil, keyEquivalent: ""); bhItem.submenu = bh
        m.addItem(bhItem)

        let sm = NSMenu()
        for s in SimNotch.allCases {
            sm.addItem(item(s.rawValue, checked: model.sim == s) { [self] in model.sim = s; apply(reason: "sim"); rebuildMenu() })
        }
        let smItem = NSMenuItem(title: "Simulated notch  (ctrl+opt+S cycles)", action: nil, keyEquivalent: ""); smItem.submenu = sm
        m.addItem(smItem)

        let dm = NSMenu()
        dm.addItem(item("Auto (first notched screen, else primary)", checked: model.screenChoice == .auto) { [self] in model.screenChoice = .auto; apply(reason: "display=auto"); rebuildMenu() })
        dm.addItem(item("Screen under mouse (at the moment you pick it)", checked: model.screenChoice == .underMouse) { [self] in model.screenChoice = .underMouse; apply(reason: "display=underMouse"); rebuildMenu() })
        for (i, s) in NSScreen.screens.enumerated() {
            var chosen = false; if case .index(let j) = model.screenChoice { chosen = i == j }
            dm.addItem(item("[\(i)] \(s.localizedName)  \(Int(s.frame.width))x\(Int(s.frame.height))\(s.safeAreaInsets.top > 0 ? "  NOTCH" : "")", checked: chosen) { [self] in model.screenChoice = .index(i); apply(reason: "display=\(i)"); rebuildMenu() })
        }
        let dmItem = NSMenuItem(title: "Display  (ctrl+opt+D cycles)", action: nil, keyEquivalent: ""); dmItem.submenu = dm
        m.addItem(dmItem)

        m.addItem(.separator())
        m.addItem(item("Diagnostics overlay", key: "h", checked: model.overlayVisible) { [self] in toggleOverlay() })
        m.addItem(item("Re-print diagnostics to console", key: "p") { [self] in apply(reason: "manual") })
        m.addItem(.separator())
        m.addItem(item("Quit", key: "q") { NSApp.terminate(nil) })
        statusItem.menu = m
    }
}

@MainActor final class ClosureItem: NSMenuItem {
    let handler: @MainActor () -> Void
    init(title: String, key: String, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { handler() }
}
