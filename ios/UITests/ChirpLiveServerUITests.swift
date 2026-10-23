import XCTest

/// End to end against a real local chirp-server (see `ios/scripts/simulator-e2e.sh`), with spoken audio from
/// `--chirp-sim-audio`. Skipped unless the runner passes CHIRP_LIVE_LINK and CHIRP_LIVE_AUDIO.
final class ChirpLiveServerUITests: XCTestCase {
    private var link = ""
    private var audio = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let link = env["CHIRP_LIVE_LINK"], !link.isEmpty, let audio = env["CHIRP_LIVE_AUDIO"], !audio.isEmpty else {
            throw XCTSkip("Live server run only: set TEST_RUNNER_CHIRP_LIVE_LINK and TEST_RUNNER_CHIRP_LIVE_AUDIO.")
        }
        self.link = link; self.audio = audio
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-sim-audio", audio]
        app.launch()
        return app
    }

    @MainActor func selectTab(_ title: String, symbol: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        if tab.exists { tab.tap(); return }
        let topTab = app.buttons.matching(identifier: symbol).firstMatch
        XCTAssertTrue(topTab.waitForExistence(timeout: 5))
        topTab.tap()
    }

    @MainActor func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor func waitFor(_ element: XCUIElement, _ format: String, _ args: Any..., timeout: TimeInterval = 20) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: args), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor func allowSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Open", "OK"] where springboard.alerts.buttons[label].waitForExistence(timeout: 1) {
            springboard.alerts.buttons[label].tap()
        }
    }

    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    /// Forget, paste the secret link, verify against the live server, save.
    @MainActor func pair(_ app: XCUIApplication) {
        selectTab("Pair Mac", symbol: "qrcode.viewfinder", in: app)
        if app.buttons["chirp.session.end"].exists { app.buttons["chirp.session.end"].tap() }
        let forget = app.buttons["Forget pairing"]
        if forget.exists { forget.tap() }
        let field = app.secureTextFields["pairingLink"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(link)
        app.buttons["Test connection and save pairing"].tap()
        XCTAssertTrue(app.staticTexts["Mac pairing saved"].waitForExistence(timeout: 15), "Live server pairing failed")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '127.0.0.1'")).firstMatch.exists)
    }

    @MainActor func testLivePairDictateCleanupRawHistoryAndEnd() {
        let app = launch()
        pair(app)
        screenshot("Paired with local server", app)

        selectTab("Styles", symbol: "sparkles", in: app)
        XCTAssertTrue(app.staticTexts["Clean-up runs on your Mac."].waitForExistence(timeout: 5))
        let cleanup = element("chirp.cleanup.enabled", in: app)
        XCTAssertTrue(cleanup.waitForExistence(timeout: 5))
        if cleanup.value as? String != "1" {
            cleanup.switches.firstMatch.exists ? cleanup.switches.firstMatch.tap() : cleanup.tap()
            let enable = app.buttons["Enable for this destination"]
            XCTAssertTrue(enable.waitForExistence(timeout: 5))
            enable.tap()
        }
        XCTAssertTrue(waitFor(cleanup, "value == '1'", timeout: 5))
        XCTAssertTrue(app.staticTexts["Default · Selected"].waitForExistence(timeout: 10), "Server styles did not load")

        selectTab("History", symbol: "clock", in: app)
        let history = element("chirp.history.enabled", in: app)
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        if history.value as? String != "1" { history.switches.firstMatch.exists ? history.switches.firstMatch.tap() : history.tap() }
        XCTAssertTrue(waitFor(history, "value == '1'", timeout: 5))

        selectTab("Dictate", symbol: "mic", in: app)
        app.buttons["chirp.dictation.start"].tap()
        allowSystemAlert()
        let stop = app.buttons["chirp.dictation.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        let transcript = app.staticTexts["transcript"]
        XCTAssertTrue(waitFor(transcript, "label CONTAINS[c] 'design group'"), "Live partials never covered the whole sentence")
        screenshot("Live partial", app)
        stop.tap()
        let raw = app.buttons["chirp.dictation.raw"]
        XCTAssertTrue(raw.waitForExistence(timeout: 20), "Clean-up did not change the text: \(transcript.label)")
        XCTAssertTrue(transcript.label.localizedCaseInsensitiveContains("Tuesday"))
        XCTAssertFalse(transcript.label.localizedCaseInsensitiveContains("um,"), transcript.label)
        XCTAssertTrue(app.staticTexts["Cleaned. Copy or share when ready."].exists)
        screenshot("Cleaned final", app)
        raw.tap()
        XCTAssertTrue(waitFor(transcript, "label CONTAINS[c] 'um,'", timeout: 3), transcript.label)
        XCTAssertTrue(app.staticTexts["Finished · microphone still active"].exists)

        selectTab("History", symbol: "clock", in: app)
        let entry = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'design group'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "History did not record the final")
        screenshot("History entry", app)

        app.buttons["chirp.session.end"].tap()
        selectTab("Dictate", symbol: "mic", in: app)
        XCTAssertTrue(app.staticTexts["Microphone off"].waitForExistence(timeout: 5))
        XCTAssertFalse(transcript.exists)
    }
}
