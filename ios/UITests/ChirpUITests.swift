import XCTest

final class ChirpUITests: XCTestCase {
    @MainActor private func selectTab(_ title: String, symbol: String, in app: XCUIApplication) {
        // iPadOS 27 exposes its top tab strip as buttons rather than a TabBar.
        let tab = app.tabBars.buttons[title]
        if tab.exists {
            tab.tap()
        } else {
            let topTab = app.buttons.matching(identifier: symbol).firstMatch
            XCTAssertTrue(topTab.waitForExistence(timeout: 5))
            topTab.tap()
        }
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
        return app
    }

    @MainActor func testSyntheticPairDictateRawAndEnd() {
        let app = pairedApp()
        selectTab("Dictate", symbol: "mic", in: app)
        app.buttons["chirp.dictation.start"].tap()
        XCTAssertTrue(app.buttons["chirp.dictation.stop"].waitForExistence(timeout: 5))
        app.buttons["chirp.dictation.stop"].tap()
        XCTAssertTrue(app.buttons["chirp.dictation.raw"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["transcript"].label, "Synthetic words.")
        app.buttons["chirp.dictation.raw"].tap()
        XCTAssertEqual(app.staticTexts["transcript"].label, "synthetic words")
        // Regression: the armed session bar covered iOS 27's tab bar, so a tab tap ended the session.
        selectTab("History", symbol: "clock", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chirp.history.enabled").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chirp.session.end"].exists, "Switching tabs must not end the session")
        selectTab("Dictate", symbol: "mic", in: app)
        XCTAssertTrue(app.staticTexts["Finished · microphone still active"].exists)
        app.buttons["chirp.session.end"].tap()
        XCTAssertTrue(app.staticTexts["Microphone off"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["transcript"].exists)
    }

    @MainActor func testHistoryOffAndAdaptiveOrientation() {
        let app = pairedApp()
        selectTab("History", symbol: "clock", in: app)
        // SwiftUI's iOS 27 toggle can be exposed as a different element type.
        let history = app.descendants(matching: .any).matching(identifier: "chirp.history.enabled").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertEqual(history.value as? String, "0")
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertEqual(history.value as? String, "0")
        XCUIDevice.shared.orientation = .portrait
        selectTab("Settings", symbol: "gear", in: app)
        XCTAssertTrue(app.staticTexts["Microphone session"].exists)
    }
}
