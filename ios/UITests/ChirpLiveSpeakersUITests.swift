import XCTest

/// Live Notes speaker labels end to end against a real local chirp-server and its real WeSpeaker model
/// (`ios/scripts/simulator-e2e.sh`, `e2e-all.sh --only speakers`): two synthetic voices (macOS `say`, Samantha then
/// Daniel, looped like a meeting) through `--chirp-sim-audio` and the rolling `/v1/stream` sockets. Labels are on by
/// default: it never touches the switch, waits for the server's own automatic model download to reach "ready" (no
/// consent alert), then requires exactly two people in the transcript, a rename from a chip that lands on every segment, and the replay of a labelled kept-audio segment.
/// Skipped unless the runner passes CHIRP_LIVE_LINK and CHIRP_LIVE_SPEAKERS_AUDIO. Reads state and counts, never text.
final class ChirpLiveSpeakersUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["CHIRP_LIVE_LINK"]?.isEmpty == false, env["CHIRP_LIVE_SPEAKERS_AUDIO"]?.isEmpty == false else {
            throw XCTSkip("Live server run only: set TEST_RUNNER_CHIRP_LIVE_LINK and TEST_RUNNER_CHIRP_LIVE_SPEAKERS_AUDIO.")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    /// The people the transcript shows now, one label per chip.
    @MainActor func chips(_ app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.speaker.chip.'")).allElementsBoundByIndex.map(\.label)
    }

    @MainActor func testTwoVoicesAreTwoPeopleRenamedEverywhereWithReplay() {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-sim-audio", env["CHIRP_LIVE_SPEAKERS_AUDIO"]!, "--chirp-skip-onboarding"]
        app.launch()
        app.openConnection()
        app.endChirpSession()
        if app.buttons["Forget pairing"].exists { app.buttons["Forget pairing"].tap() }
        let field = app.pairingLinkField()
        field.tap(); field.typeText(env["CHIRP_LIVE_LINK"]!)
        app.buttons["chirp.pair.submit"].tap()
        XCTAssertTrue(app.staticTexts["Mac pairing saved"].waitForExistence(timeout: 15))

        ChirpNotesUITests.openNotes(app)
        app.buttons["chirp.notes.menu"].tap()
        app.buttons["chirp.notes.settings"].tap()
        let keepAudio = ChirpNotesUITests.element("chirp.notes.keepAudio", in: app)
        XCTAssertTrue(keepAudio.waitForExistence(timeout: 5))
        if keepAudio.value as? String != "1" { ChirpNotesUITests.flipInSheet(keepAudio, in: app) }

        // Labels are on by default and the Mac has no speaker model yet: no switch to flip and no consent. The phone
        // asks the Mac for its one pinned download itself; Settings follows it until the model is ready.
        let toggle = ChirpNotesUITests.element("chirp.notes.speakers.setting", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); XCTAssertEqual(toggle.value as? String, "1", "Labels must be on by default")
        XCTAssertFalse(app.alerts.firstMatch.exists, "The download starts without a prompt")
        screenshot("Speakers on by default on the live server", app)
        let model = ChirpNotesUITests.element("chirp.notes.speakers.model", in: app)
        XCTAssertTrue(ChirpNotesUITests.waitFor(model, "label == 'Speaker model on your Mac: ready'", timeout: 240),
                      "The automatic download never made the model ready: \(model.exists ? model.label : "no status")")
        screenshot("Speakers model ready on the live server", app)
        app.buttons["Done"].tap()

        let record = app.buttons["chirp.notes.record"]
        XCTAssertTrue(ChirpNotesUITests.waitFor(record, "isEnabled == true", timeout: 10))
        record.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] where springboard.alerts.buttons[label].waitForExistence(timeout: 1) { springboard.alerts.buttons[label].tap() }
        let status = ChirpNotesUITests.element("chirp.notes.status", in: app)
        XCTAssertTrue(ChirpNotesUITests.waitFor(status, "label == 'Recording'", timeout: 20), status.label)
        // The asset plays once at real-time pace (about 40 s), then silence.
        sleep(50)
        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(status, "label == 'Stopped'", timeout: 90), status.label)

        app.buttons["chirp.notes.transcript.open"].tap()
        let transcript = ChirpNotesUITests.element("chirp.notes.transcript", in: app)
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.speaker.chip.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), "No speaker chip in the transcript")
        let people = Set(chips(app))
        XCTAssertEqual(people, ["Person 1", "Person 2"], "Two voices must be exactly two people: \(people)")
        screenshot("Speakers two people from the live server", app)

        // Rename Person 2 from a chip: the new name replaces it on every segment.
        let two = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.speaker.chip.' AND label == 'Person 2'")).firstMatch
        two.tap()
        app.buttons["chirp.notes.speaker.rename"].tap()
        let name = app.textFields["chirp.notes.speaker.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Maya")
        app.buttons["chirp.notes.speaker.confirm"].tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(first, "label == 'Person 1' OR label == 'Maya'", timeout: 10))
        XCTAssertEqual(Set(chips(app)), ["Person 1", "Maya"], "The rename must reach every segment")
        screenshot("Speakers renamed on the live server", app)

        // Kept audio still replays per segment in a labelled transcript.
        let play = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.play.'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), "No kept audio to replay in the labelled transcript")
        play.tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(play, "label == 'Stop replay'", timeout: 10))
    }
}
