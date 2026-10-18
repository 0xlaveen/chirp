import XCTest

final class ChirpUITests: XCTestCase {
    @MainActor func pairedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test"]
        app.launch()
        app.tabBars.buttons["Pair Mac"].tap()
        let link = app.secureTextFields["pairingLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        link.typeText("chirp://pair?url=https%3A%2F%2Fsynthetic.test.ts.net%2Fchirp&token=synthetic-only")
        app.buttons["Test connection and save pairing"].tap()
        XCTAssertTrue(app.staticTexts["Mac pairing saved"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor func testSyntheticPairDictateRawAndEnd() {
        let app = pairedApp()
        app.tabBars.buttons["Dictate"].tap()
        app.buttons["Dictate"].tap()
        XCTAssertTrue(app.buttons["Stop dictation"].waitForExistence(timeout: 5))
        app.buttons["Stop dictation"].tap()
        XCTAssertTrue(app.buttons["Use raw"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["transcript"].label, "Synthetic words.")
        app.buttons["Use raw"].tap()
        XCTAssertEqual(app.staticTexts["transcript"].label, "synthetic words")
        app.buttons["End session"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Microphone off"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["transcript"].exists)
    }

    @MainActor func testHistoryOffAndAdaptiveOrientation() {
        let app = pairedApp()
        app.tabBars.buttons["History"].tap()
        let history = app.switches["Keep encrypted history on this device"]
        XCTAssertEqual(history.value as? String, "0")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Microphone session"].exists)
    }
}
