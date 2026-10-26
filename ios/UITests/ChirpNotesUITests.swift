import XCTest

/// The Notes library through the real sealed store, with synthetic capture and server responses.
final class ChirpNotesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDown() async throws { await MainActor.run { XCUIApplication().terminate() } }

    @MainActor static func openNotes(_ app: XCUIApplication) {
        app.selectChirpTab("Notes")
    }
    @MainActor static func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor static func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 15) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }
    @MainActor static func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }
    /// Flips a switch in the Notes settings sheet. On iPad that sheet is shorter and narrower than the form: a row near
    /// the end exists but sits below the sheet until it is scrolled into view, and a tap outside the sheet dismisses it.
    /// So scroll until the row is hittable, then aim from the sheet's own Done button.
    @MainActor static func flipInSheet(_ toggle: XCUIElement, in app: XCUIApplication) {
        var scrolls = 0
        while !toggle.isHittable, scrolls < 6 { app.swipeUp(velocity: .slow); scrolls += 1 }
        let done = app.buttons["Done"].firstMatch
        guard done.exists, toggle.frame.height > 0 else { return flip(toggle) }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: done.frame.maxX - 36, dy: toggle.frame.midY)).tap()
    }
    /// Both appearances in one test invocation; no separate simulator configuration or app relaunch is needed.
    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let original = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = original }
        let fixed = ProcessInfo.processInfo.environment["CHIRP_NOTES_APPEARANCE"]
        let appearances: [XCUIDevice.Appearance] = fixed == "dark" ? [.dark] : fixed == "light" ? [.light] : [.light, .dark]
        for appearance in appearances {
            if fixed == nil { XCUIDevice.shared.appearance = appearance }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name + (appearance == .dark ? "-dark" : "-light")
            shot.lifetime = .keepAlways
            add(shot)
        }
    }
    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test", "--chirp-skip-onboarding", "--chirp-notes-library-id", UUID().uuidString] + extra
        if let appearance = ProcessInfo.processInfo.environment["CHIRP_NOTES_APPEARANCE"] {
            app.launchArguments += ["-AppleInterfaceStyle", appearance == "dark" ? "Dark" : "Light"]
        }
        app.launch(); Self.openNotes(app)
        XCTAssertTrue(Self.element("chirp.notes.library", in: app).waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func backToLibrary(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom != .pad {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        }
    }
    @MainActor private func menu(_ app: XCUIApplication, action: String) {
        app.buttons["chirp.notes.export"].tap()
        let button = app.buttons[action]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }

    /// One XCTest case keeps all scenarios in one runner session, avoiding repeated simulator teardown stalls.
    @MainActor func testNotesLibraryBatch() {
        recordPauseResumeStopTranscriptAndExport()
        libraryReadingSearchTasksAndInspector()
        notesSettingsAndRotation()
        accessibilityLibraryAndDock()
    }

    /// Refresh only the captures where a library snippet is visible, in one bounded run per device.
    @MainActor func testLibrarySnippetScreenshots() {
        let original = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = original }
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        if pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let fixed = ProcessInfo.processInfo.environment["CHIRP_NOTES_APPEARANCE"]
        let appearances: [XCUIDevice.Appearance] = fixed == "dark" ? [.dark] : fixed == "light" ? [.light] : [.light, .dark]
        for appearance in appearances {
            let app = launch(["--chirp-notes-gallery"])
            if fixed == nil { XCUIDevice.shared.appearance = appearance }
            func capture(_ name: String) {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = name + (appearance == .dark ? "-dark" : "-light")
                shot.lifetime = .keepAlways
                add(shot)
            }
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            XCTAssertTrue(row.label.contains("Agenda · Review the launch plan · Share the design brief"))
            XCTAssertFalse(row.label.contains("Lantern kickoff Agenda"))
            capture("notes-library-groups")
            row.tap()
            XCTAssertTrue(app.buttons["chirp.notes.title"].waitForExistence(timeout: 5))
            if pad {
                capture("notes-reading")
                app.buttons["chirp.notes.transcript.open"].tap()
                let play = app.buttons["chirp.notes.play.0"]
                XCTAssertTrue(play.waitForExistence(timeout: 5))
                play.tap()
                XCTAssertTrue(Self.waitFor(play, "label == 'Stop replay'", timeout: 5))
                XCTAssertTrue(Self.waitFor(play, "label == 'Play segment'"), "Replay completion returns to the main actor")
                if appearance == .light { capture("notes-transcript-audio") }
                Self.flip(Self.element("chirp.notes.raw", in: app))
                capture("notes-transcript")
            } else {
                menu(app, action: "Delete")
                app.buttons["chirp.notes.menu"].tap(); app.buttons["chirp.notes.deleted.menu"].tap()
                XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 5))
                capture("notes-recently-deleted")
            }
            app.terminate()
        }
    }

    @MainActor private func recordPauseResumeStopTranscriptAndExport() {
        let app = launch()
        screenshot("notes-empty", app)
        app.buttons["chirp.notes.record"].firstMatch.tap()
        let status = Self.element("chirp.notes.status", in: app)
        XCTAssertTrue(Self.waitFor(status, "label == 'Recording'"))
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.partial", in: app), "label == 'synthetic words'"))
        screenshot("notes-recording", app)
        backToLibrary(app)
        XCTAssertTrue(app.buttons["chirp.notes.recordingRow"].waitForExistence(timeout: 5))
        screenshot("notes-library-recording", app)
        app.buttons["chirp.notes.recordingRow"].tap()
        app.buttons["chirp.notes.pause"].tap()
        XCTAssertTrue(Self.waitFor(status, "label BEGINSWITH 'Paused'"))
        // Labels are on by default, so the synthetic note reads "Person 1: Synthetic words.".
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Synthetic words.'")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["chirp.notes.pause"].tap()
        XCTAssertTrue(Self.waitFor(status, "label == 'Recording'"))
        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(Self.waitFor(status, "label == 'Stopped'"))
        screenshot("notes-stopped", app)
        app.buttons["chirp.notes.edit"].tap()
        let editor = app.textViews["chirp.notes.editor"]
        XCTAssertTrue(Self.waitFor(editor, "value CONTAINS 'Synthetic words.'"))
        screenshot("notes-edit", app)
        app.buttons["chirp.notes.edit"].tap()
        app.buttons["chirp.notes.transcript.open"].tap()
        let transcript = Self.element("chirp.notes.transcript", in: app)
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        Self.flip(Self.element("chirp.notes.raw", in: app))
        XCTAssertTrue(transcript.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'synthetic words'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("notes-transcript", app)
        if UIDevice.current.userInterfaceIdiom != .pad { app.buttons["Done"].tap() }
        else { app.buttons["chirp.notes.transcript.open"].tap() }
        menu(app, action: "chirp.notes.copy")
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.notice", in: app), "label CONTAINS 'Copied notes'"))
        backToLibrary(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("notes-library-after-recording", app)
        app.terminate(); app.launch(); Self.openNotes(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The sealed note survives relaunch")
        row.tap()
        XCTAssertTrue(app.buttons["chirp.notes.title"].waitForExistence(timeout: 5))
        menu(app, action: "Delete")
        let undo = app.buttons["chirp.notes.delete.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5)); undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap(); menu(app, action: "Delete")
        app.buttons["chirp.notes.menu"].tap(); app.buttons["chirp.notes.deleted.menu"].tap()
        XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 5))
        screenshot("notes-recently-deleted", app)
        app.buttons["Restore"].tap()
        XCTAssertTrue(app.staticTexts["Nothing in Recently Deleted"].waitForExistence(timeout: 5))
    }

    @MainActor private func notesSettingsAndRotation() {
        let app = launch()
        app.buttons["chirp.notes.menu"].tap(); app.buttons["chirp.notes.settings"].tap()
        let saver = Self.element("chirp.notes.batterySaver", in: app)
        XCTAssertTrue(saver.waitForExistence(timeout: 5)); XCTAssertEqual(saver.value as? String, "1")
        XCTAssertEqual(Self.element("chirp.notes.keepNotes", in: app).value as? String, "1")
        XCTAssertEqual(Self.element("chirp.notes.keepAudio", in: app).value as? String, "0")
        XCTAssertTrue(app.staticTexts["Never"].exists)
        screenshot("notes-settings", app)
        app.buttons["Done"].tap()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["chirp.notes.record"].firstMatch.waitForExistence(timeout: 5))
        screenshot("notes-library-landscape", app)
    }

    /// Reading, tasks, rename, local search and the inspector, with both appearances captured in this run.
    @MainActor private func libraryReadingSearchTasksAndInspector() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch(["--chirp-notes-gallery"])
        XCTAssertTrue(app.staticTexts["Lantern kickoff"].waitForExistence(timeout: 10))
        screenshot("notes-library-groups", app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
        XCTAssertTrue(row.exists); row.tap()
        XCTAssertTrue(app.staticTexts["Decision:"].exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Keep the launch in March'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("notes-reading", app)
        let task = Self.element("chirp.notes.preview", in: app).buttons.matching(NSPredicate(format: "label CONTAINS 'Send the updated proposal'")).firstMatch
        if task.exists { task.tap(); XCTAssertEqual(task.value as? String, "Checked") }
        app.buttons["chirp.notes.transcript.open"].tap()
        XCTAssertTrue(app.buttons["chirp.notes.play.0"].waitForExistence(timeout: 5))
        app.buttons["chirp.notes.play.0"].tap()
        screenshot("notes-transcript-audio", app)
        if UIDevice.current.userInterfaceIdiom != .pad { app.buttons["Done"].tap() }
        else { app.buttons["chirp.notes.transcript.open"].tap() }
        app.buttons["chirp.notes.edit"].tap(); screenshot("notes-reading-edit", app)
        app.buttons["chirp.notes.edit"].tap()
        app.buttons["chirp.notes.title"].tap()
        let title = app.textFields["chirp.notes.title.editor"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (title.value as? String)?.count ?? 32) + "Launch notes")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chirp.notes.title"].waitForExistence(timeout: 5))
        backToLibrary(app)
        app.buttons["Search notes"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
        var prefix = ""
        for character in "March" {
            search.typeText(String(character)); prefix.append(character)
            XCTAssertTrue(Self.waitFor(search, "value == '\(prefix)'", timeout: 3))
        }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'March'")).firstMatch.waitForExistence(timeout: 5))
        search.typeText("\n")
        screenshot("notes-search", app)
    }

    @MainActor private func accessibilityLibraryAndDock() {
        let app = launch(["--chirp-notes-gallery", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        screenshot("notes-library-ax5", app)
        app.buttons["chirp.notes.record"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chirp.notes.stop"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chirp.notes.pause"].isHittable)
        screenshot("notes-dock-ax5", app)
        app.buttons["chirp.notes.stop"].tap()
    }

    /// Label speakers (#201) with the synthetic server: the switch in Settings → Notes, two chips in the transcript,
    /// then rename (with the notes replaced), merge and separate from a chip's menu.
    @MainActor func testSpeakerChipsRenameMergeAndSeparate() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch(["--chirp-notes-gallery", "--chirp-speakers-gallery"])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        app.buttons["chirp.notes.transcript.open"].tap()
        let one = app.buttons["chirp.notes.speaker.chip.0.0"], two = app.buttons["chirp.notes.speaker.chip.0.1"]
        XCTAssertTrue(one.waitForExistence(timeout: 5))
        XCTAssertEqual(one.label, "Person 1"); XCTAssertEqual(two.label, "Maya")
        screenshot("notes-speakers-transcript", app)

        // Rename Person 1 → Theo, replacing the notes' "Person 1" too.
        one.tap()
        app.buttons["chirp.notes.speaker.rename"].tap()
        let name = app.textFields["chirp.notes.speaker.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Theo")
        XCTAssertTrue(Self.element("chirp.notes.speaker.replace", in: app).waitForExistence(timeout: 5))
        screenshot("notes-speakers-rename", app)
        app.buttons["chirp.notes.speaker.confirm"].tap()
        XCTAssertTrue(Self.waitFor(one, "label == 'Theo'", timeout: 5))

        // Merge Maya into Theo, then separate her again.
        two.tap()
        app.buttons["chirp.notes.speaker.merge"].tap()
        app.buttons["Theo"].firstMatch.tap()
        XCTAssertTrue(Self.waitFor(two, "label == 'Theo'", timeout: 5))
        screenshot("notes-speakers-merged", app)
        two.tap()
        app.buttons["chirp.notes.speaker.separate"].tap()
        XCTAssertTrue(Self.waitFor(two, "label == 'Maya'", timeout: 5))

        if UIDevice.current.userInterfaceIdiom != .pad { app.buttons["Done"].tap() }
        else { app.buttons["chirp.notes.transcript.open"].tap() }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Theo'")).firstMatch.waitForExistence(timeout: 5),
                      "the rename replaced the name in the notes")
    }

    /// Labels are on by default: no switch to flip and no consent (the synthetic Mac has the model), the chips follow, and
    /// Turn off in Settings is the one explicit choice.
    @MainActor func testLabelSpeakersAreOnByDefaultAndSettingsTurnsThemOff() {
        let app = launch()
        // Paired (the synthetic Mac answers health) before Settings is read: otherwise the Mac's model is unknown.
        XCTAssertTrue(Self.waitFor(app.buttons["chirp.notes.record"].firstMatch, "isEnabled == true", timeout: 20))
        app.buttons["chirp.notes.menu"].tap(); app.buttons["chirp.notes.settings"].tap()
        let toggle = Self.element("chirp.notes.speakers.setting", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "1")
        let model = Self.element("chirp.notes.speakers.model", in: app)
        XCTAssertTrue(Self.waitFor(model, "label == 'Speaker model on your Mac: ready'", timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists, "Labels on by default never ask")
        screenshot("notes-settings-speakers-sheet", app)
        app.buttons["Done"].tap()
        app.buttons["chirp.notes.record"].firstMatch.tap()
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.status", in: app), "label == 'Recording'"))
        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.status", in: app), "label == 'Stopped'"))
        app.buttons["chirp.notes.transcript.open"].tap()
        XCTAssertTrue(app.buttons["chirp.notes.speaker.chip.0.0"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["chirp.notes.speaker.chip.0.1"].label, "Person 2")
        if UIDevice.current.userInterfaceIdiom != .pad { app.buttons["Done"].tap() }
        else { app.buttons["chirp.notes.transcript.open"].tap() }

        // Turn off is the user's own choice: the switch reads off.
        // The note's own ⋯ menu (the library's is not on screen on an iPhone).
        XCTAssertTrue(app.buttons["chirp.notes.export"].waitForExistence(timeout: 10))
        app.buttons["chirp.notes.export"].tap(); app.buttons["chirp.notes.settings"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        Self.flipInSheet(toggle, in: app)
        XCTAssertTrue(Self.waitFor(toggle, "value == '0'", timeout: 10))
        screenshot("notes-settings-speakers", app)
    }
    @MainActor func testNameSpeakersSheetCancelNameMergeAndReopen() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch(["--chirp-notes-gallery", "--chirp-speakers-gallery"])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        let open = app.buttons["chirp.notes.speakers.name.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        screenshot("notes-speakers-name-line", app)
        open.tap()
        let name = app.textFields["chirp.notes.speakers.name.1"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        screenshot("notes-speakers-name-sheet", app)
        name.tap(); name.typeText("Theo")
        XCTAssertTrue(Self.element("chirp.notes.speakers.replace", in: app).exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Person 1")
        name.tap(); name.typeText("Theo")
        app.buttons["chirp.notes.speakers.name.done"].tap()
        XCTAssertFalse(open.exists)
        app.buttons["chirp.notes.transcript.open"].tap()
        let one = app.buttons["chirp.notes.speaker.chip.0.0"]
        XCTAssertTrue(Self.waitFor(one, "label == 'Theo'", timeout: 10))
        app.buttons["chirp.notes.speakers.name.header"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.buttons["chirp.notes.speakers.same.2"].tap()
        let merge = app.buttons["chirp.notes.speakers.merge.into.1"].firstMatch
        XCTAssertTrue(merge.waitForExistence(timeout: 5)); merge.tap()
        XCTAssertFalse(app.textFields["chirp.notes.speakers.name.2"].exists)
        app.buttons["chirp.notes.speakers.name.done"].tap()
        XCTAssertTrue(Self.waitFor(app.buttons["chirp.notes.speaker.chip.0.1"], "label == 'Theo'", timeout: 5))
    }

    @MainActor func testNameSpeakersEvidence() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch(["--chirp-notes-gallery", "--chirp-speakers-gallery"])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        let open = app.buttons["chirp.notes.speakers.name.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        screenshot("notes-speakers-name-line", app)
        open.tap()
        let name = app.textFields["chirp.notes.speakers.name.1"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("Theo\n")
        screenshot("notes-speakers-name-sheet", app)
    }

}
