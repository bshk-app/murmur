import XCTest

/// Uses a real photo in Documents/photo-probe.jpg and a verified local en→fi model.
/// The test never substitutes an OCR or MT result.
final class PhotoTranslationUITests: XCTestCase {
    func testPartialFailureCanBeCorrectedAndRetried() {
        let app = XCUIApplication()
        app.launchArguments = ["--photo-translation-probe", "-AppleLanguages", "(en)"]
        app.launchEnvironment["PHOTO_PROBE_TARGET"] = "fi"
        app.launchEnvironment["PHOTO_PROBE_FIXTURE"] = "partial-failure"
        app.launchEnvironment["OCR_PROBE_DILATE"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["photo-translate"].waitForExistence(timeout: 30))
        waitIdle(app)
        XCTAssertTrue(app.staticTexts["photo-error"].exists)
        let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-retry-")).firstMatch
        XCTAssertTrue(retry.exists)
        let retryID = retry.identifier
        let blockID = retryID.replacingOccurrences(of: "photo-retry-", with: "photo-block-")
        let block = app.buttons[blockID]
        // XCTest scrolls the exact row into view; fixed swipes can overshoot in the compact panel.
        block.tap()
        let editFailed = app.buttons["photo-edit-failed"]
        XCTAssertTrue(editFailed.waitForExistence(timeout: 5))
        editFailed.tap()
        let editor = app.textViews["photo-original-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let oldText = editor.value as? String ?? ""
        editor.tap()
        // Select all using the edit menu so the test does not depend on caret position.
        editor.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) { selectAll.tap(); editor.typeText("Welcome") }
        else { XCTFail("Select All unavailable for correcting fixture: \(oldText.count) characters"); return }
        app.buttons["photo-save-correction"].tap()
        let retryAfterEdit = app.buttons[retryID]
        XCTAssertTrue(retryAfterEdit.waitForExistence(timeout: 5))
        retryAfterEdit.tap()
        waitIdle(app)
        XCTAssertFalse(app.buttons[retryID].exists)
        XCTAssertTrue(app.buttons[blockID].label.contains("Tervetuloa"))
    }
    func testOpenAndCloseFromNotes() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertFalse(app.buttons["photo-translation"].exists)
        let open = app.buttons["Translate"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let modes = app.segmentedControls["translation-mode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        modes.buttons["Text"].tap()
        let input = app.textViews["text-translation-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("Keep this draft")
        let hideKeyboard = app.buttons["text-hide-keyboard"]
        if hideKeyboard.exists { hideKeyboard.tap() }
        modes.buttons["Photo"].tap()
        XCTAssertTrue(app.buttons["photo-import"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["photo-close"].exists)
        modes.buttons["Voice"].tap()
        XCTAssertTrue(app.buttons["start-translation"].waitForExistence(timeout: 5))
        modes.buttons["Text"].tap()
        XCTAssertTrue((input.value as? String ?? "").contains("Keep this draft"))
        modes.buttons["Photo"].tap()
        XCTAssertTrue(app.buttons["photo-import"].waitForExistence(timeout: 10))
        app.buttons["photo-import"].tap()
        let cancelPicker = app.buttons["Cancel"]
        XCTAssertTrue(cancelPicker.waitForExistence(timeout: 5))
        cancelPicker.tap()
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        XCTAssertTrue(modes.buttons["Text"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Translate-Photo-tab"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["translation-close"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        waitEnabled(open)
    }
    func testPhotoTranslationCorrectionAndCancellation() {
        let app = XCUIApplication()
        app.launchArguments = ["--photo-translation-probe", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["PHOTO_PROBE_TARGET"] = "fi"
        app.launchEnvironment["PHOTO_CANCEL_TEST_DELAY"] = "1"
        app.launch()
        let translate = app.buttons["photo-translate"]
        XCTAssertTrue(translate.waitForExistence(timeout: 30))
        waitIdle(app)
        XCTAssertFalse(app.staticTexts["photo-error"].exists)
        let region = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-region-")).firstMatch
        XCTAssertTrue(region.waitForExistence(timeout: 10))
        app.buttons["photo-original-toggle"].tap()
        region.tap()
        let editor = app.textViews["photo-original-editor"]
        let editorAppeared = editor.waitForExistence(timeout: 5)
        if !editorAppeared { print(app.debugDescription) }
        XCTAssertTrue(editorAppeared)
        editor.tap(); editor.typeText(" Welcome")
        XCTAssertTrue((editor.value as? String ?? "").contains("Welcome"))
        app.buttons["photo-save-correction"].tap()
        XCTAssertTrue(translate.waitForExistence(timeout: 5))
        translate.tap(); waitIdle(app)
        XCTAssertFalse(app.staticTexts["photo-error"].exists)
        app.buttons["photo-rotate"].tap()
        let cancel = app.buttons["photo-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap(); waitEnabled(translate)
        XCTAssertFalse(app.staticTexts["photo-error"].exists)
    }
    private func waitEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed)
    }
    private func waitIdle(_ app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["photo-translate"].exists && !app.buttons["photo-cancel"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed)
    }
}
