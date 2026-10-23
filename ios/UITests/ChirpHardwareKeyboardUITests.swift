import XCTest

/// Rotation mid-dictation, the app's Dictation menu shortcuts, and the Settings path where iPadOS lets a
/// key run Chirp's Toggle action from other apps. Synthetic transport; no server.
final class ChirpHardwareKeyboardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    @MainActor func selectTab(_ title: String, symbol: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        if tab.exists { tab.tap(); return }
        let topTab = app.buttons.matching(identifier: symbol).firstMatch
        XCTAssertTrue(topTab.waitForExistence(timeout: 5))
        topTab.tap()
    }

    @MainActor func waitFor(_ element: XCUIElement, _ format: String, _ args: Any..., timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: args), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func pairedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test"]
        app.launch()
        selectTab("Pair Mac", symbol: "qrcode.viewfinder", in: app)
        let link = app.secureTextFields["pairingLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        link.typeText("chirp://pair?url=https%3A%2F%2Fsynthetic.test.ts.net%2Fchirp&token=synthetic-only")
        app.buttons["Test connection and save pairing"].tap()
        XCTAssertTrue(app.staticTexts["Mac pairing saved"].waitForExistence(timeout: 5))
        selectTab("Dictate", symbol: "mic", in: app)
        return app
    }

    /// Rotating while listening keeps the utterance, its live text and the controls; it finishes normally.
    @MainActor func testRotationDuringDictationKeepsUtterance() {
        let app = pairedApp()
        let status = app.staticTexts["sessionStatus"], transcript = app.staticTexts["transcript"]
        app.buttons["chirp.dictation.start"].tap()
        XCTAssertTrue(waitFor(transcript, "label == 'synthetic words'"))
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(waitFor(status, "label == 'Listening…'"), "Rotation to \(orientation.rawValue) must not end the utterance")
            XCTAssertEqual(transcript.label, "synthetic words")
            XCTAssertTrue(app.buttons["chirp.dictation.stop"].isHittable)
        }
        screenshot("Listening in landscape", app)
        app.buttons["chirp.dictation.stop"].tap()
        XCTAssertTrue(waitFor(transcript, "label == 'Synthetic words.'"))
        app.buttons["chirp.dictation.raw"].tap()
        XCTAssertTrue(waitFor(transcript, "label == 'synthetic words'"))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitFor(status, "label == 'Finished · microphone still active'"))
    }

    /// ⌘Return starts and stops, ⌘⇧Z uses raw, ⌘⇧C copies, ⌘. cancels, ⌘⇧E ends and ⌘⇧K arms.
    /// Needs a hardware keyboard connected to the simulator (Simulator → I/O → Keyboard); headless
    /// simulators drop synthesized key events, which the Esc probe detects.
    @MainActor func testDictationMenuShortcuts() throws {
        let app = pairedApp()
        let status = app.staticTexts["sessionStatus"], transcript = app.staticTexts["transcript"]
        app.buttons["chirp.dictation.start"].tap()
        XCTAssertTrue(waitFor(status, "label == 'Listening…'"))
        app.typeKey(.escape, modifierFlags: [])
        guard waitFor(status, "label == 'Session armed · microphone active'", timeout: 3) else {
            throw XCTSkip("Synthesized hardware key events do not reach the app: no hardware keyboard is connected to this simulator.")
        }
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitFor(transcript, "label == 'synthetic words'"), "⌘Return did not start dictation")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitFor(transcript, "label == 'Synthetic words.'"), "⌘Return did not stop dictation")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(transcript, "label == 'synthetic words'"), "⌘⇧Z did not use raw")
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(app.staticTexts["sessionNotice"], "label == 'Copied.'"), "⌘⇧C did not copy")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitFor(status, "label == 'Listening…'"))
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(waitFor(status, "label == 'Session armed · microphone active'"), "⌘. did not cancel")
        app.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(status, "label == 'Microphone off'"), "⌘⇧E did not end the session")
        app.typeKey("k", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(status, "label == 'Session armed · microphone active'"), "⌘⇧K did not arm")
    }

    /// The README and in-app help send iPad users to Full Keyboard Access → Commands to give their Toggle
    /// shortcut a key. iOS lists Shortcuts-app shortcuts there once one exists; this checks the path.
    @MainActor func testFullKeyboardAccessCommandsPath() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        defer { settings.terminate() }
        try tapSettings("Accessibility", in: settings)
        let keyboards = ["Keyboards & Typing", "Keyboards"].map { settingsItem($0, in: settings) }.first { $0.waitForExistence(timeout: 3) }
        guard let keyboards else { throw XCTSkip("Accessibility has no Keyboards row on this OS") }
        let keyboardsLabel = keyboards.label
        keyboards.tap()
        try tapSettings("Full Keyboard Access", in: settings)
        try tapSettings("Commands", in: settings)
        let hint = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Tap any command to customize its keyboard shortcut.'")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "Commands page did not open")
        let path = XCTAttachment(string: "Accessibility → \(keyboardsLabel) → Full Keyboard Access → Commands")
        path.name = "Verified Settings path"; path.lifetime = .keepAlways
        add(path)
        print("CHIRP-FKA-PATH Accessibility → \(keyboardsLabel) → Full Keyboard Access → Commands")
    }
}
