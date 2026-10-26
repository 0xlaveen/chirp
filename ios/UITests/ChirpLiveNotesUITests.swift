import XCTest

/// Live Notes end to end against a real local chirp-server (`ios/scripts/simulator-e2e.sh`): spoken audio from
/// `--chirp-sim-audio`, real segments over `/v1/stream`, clean-up and `/v1/notes/structure` through the local
/// stand-in. Skipped unless the runner passes CHIRP_LIVE_LINK and CHIRP_LIVE_AUDIO.
final class ChirpLiveNotesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["CHIRP_LIVE_LINK"]?.isEmpty == false, env["CHIRP_LIVE_AUDIO"]?.isEmpty == false else {
            throw XCTSkip("Live server run only: set TEST_RUNNER_CHIRP_LIVE_LINK and TEST_RUNNER_CHIRP_LIVE_AUDIO.")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testLiveNotesRecordStructureStop() {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-sim-audio", env["CHIRP_LIVE_AUDIO"]!, "--chirp-skip-onboarding"]
        app.launch()
        // Pair through Settings → Connection like the dictation live test.
        app.openConnection()
        app.endChirpSession()
        if app.buttons["Forget pairing"].exists { app.buttons["Forget pairing"].tap() }
        let field = app.pairingLinkField()
        field.tap(); field.typeText(env["CHIRP_LIVE_LINK"]!)
        app.buttons["chirp.pair.submit"].tap()
        XCTAssertTrue(app.staticTexts["Mac pairing saved"].waitForExistence(timeout: 15))
        // Clean-up on, so segments are cleaned and Show raw has something to show (pairing again turned it off).
        app.openStyles()
        let cleanup = ChirpNotesUITests.element("chirp.cleanup.enabled", in: app)
        XCTAssertTrue(cleanup.waitForExistence(timeout: 5))
        if cleanup.value as? String != "1" {
            cleanup.switches.firstMatch.exists ? cleanup.switches.firstMatch.tap() : cleanup.tap()
            let enable = app.buttons["Enable for this destination"]
            if enable.waitForExistence(timeout: 3) { enable.tap() }
        }
        XCTAssertTrue(ChirpNotesUITests.waitFor(cleanup, "value == '1'", timeout: 5))

        ChirpNotesUITests.openNotes(app)
        app.buttons["chirp.notes.menu"].tap()
        app.buttons["chirp.notes.settings"].tap()
        let keepAudio = ChirpNotesUITests.element("chirp.notes.keepAudio", in: app)
        XCTAssertTrue(keepAudio.waitForExistence(timeout: 5))
        if keepAudio.value as? String != "1" { ChirpNotesUITests.flip(keepAudio) }
        app.buttons["Done"].tap()
        let record = app.buttons["chirp.notes.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertTrue(ChirpNotesUITests.waitFor(record, "isEnabled == true", timeout: 10))
        record.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] where springboard.alerts.buttons[label].waitForExistence(timeout: 1) { springboard.alerts.buttons[label].tap() }
        let status = ChirpNotesUITests.element("chirp.notes.status", in: app)
        XCTAssertTrue(ChirpNotesUITests.waitFor(status, "label == 'Recording'", timeout: 20), status.label)
        let partial = ChirpNotesUITests.element("chirp.notes.partial", in: app)
        XCTAssertTrue(ChirpNotesUITests.waitFor(partial, "label CONTAINS[c] 'design group'", timeout: 30), "Live partial never covered the sentence")
        screenshot("Live Notes live partial", app)

        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(status, "label == 'Stopped'", timeout: 60), status.label)
        let preview = ChirpNotesUITests.element("chirp.notes.preview", in: app)
        XCTAssertTrue(preview.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'design group'")).firstMatch.waitForExistence(timeout: 10))
        screenshot("Notes reading from the live server", app)
        app.buttons["chirp.notes.edit"].tap()
        let editor = app.textViews["chirp.notes.editor"]
        XCTAssertTrue(ChirpNotesUITests.waitFor(editor, "value CONTAINS[c] 'design group'", timeout: 10))
        let markdown = editor.value as? String ?? ""
        XCTAssertTrue(markdown.hasPrefix("- "), "The live server stand-in structures a bullet")
        XCTAssertFalse(markdown.localizedCaseInsensitiveContains("um,"))
        app.buttons["chirp.notes.edit"].tap()
        app.buttons["chirp.notes.transcript.open"].tap()
        let transcript = ChirpNotesUITests.element("chirp.notes.transcript", in: app)
        XCTAssertTrue(transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Tuesday'")).firstMatch.waitForExistence(timeout: 5))
        ChirpNotesUITests.flip(ChirpNotesUITests.element("chirp.notes.raw", in: app))
        XCTAssertTrue(transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'um,'")).firstMatch.waitForExistence(timeout: 5),
                      "Show raw shows the transcript before clean-up")
        screenshot("Notes raw transcript from the live server", app)
        let play = app.buttons["chirp.notes.play.0"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Opted-in speech audio survives Stop")
        play.tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(play, "label == 'Stop replay'", timeout: 5))
        screenshot("Notes kept audio replay from the live server", app)
    }
}
