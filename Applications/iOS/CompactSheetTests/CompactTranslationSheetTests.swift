import XCTest

final class CompactTranslationSheetTests: XCTestCase {
    func testKeyboardHidesPreviouslyInsertedResult() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.bshk.murmur.uitesthost")
        app.launchArguments = ["--keyboard-result-test", "--result-handled", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["keyboard-status"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["keyboard-insert-result"].exists, "Fixture must be acknowledged before checking stale preview")
        XCTAssertFalse(app.textViews["keyboard-live-text"].exists, "Previously inserted translation must not remain in an inactive keyboard")
        capture(app, "keyboard-consumed-result-cleared")
    }
    func testKeyboardCanDiscardPendingResultWithoutLosingItOnDeactivation() {
        continueAfterFailure = false
        for inactive in [false, true] {
            let app = XCUIApplication(bundleIdentifier: "app.bshk.murmur.uitesthost")
            app.launchArguments = ["--keyboard-result-test", "-AppleLanguages", "(en)"] + (inactive ? ["--result-inactive"] : [])
            app.launch()
            XCTAssertTrue(app.textViews["keyboard-live-text"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.textViews["keyboard-live-text"].value as? String, "Yksi, kaksi, kolme.")
            XCTAssertTrue(app.buttons["keyboard-insert-result"].exists)
            capture(app, inactive ? "keyboard-pending-inactive" : "keyboard-pending-result")
            app.buttons["keyboard-clear-result"].tap()
            XCTAssertFalse(app.textViews["keyboard-live-text"].exists)
            XCTAssertFalse(app.buttons["keyboard-insert-result"].exists)
            if !inactive { XCTAssertTrue(app.buttons["keyboard-hold-to-talk"].isHittable) }
            capture(app, inactive ? "keyboard-cleared-inactive" : "keyboard-cleared-ready")
        }
    }
    func testSettingsVersionAndSafariHelp() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.bshk.murmur.uitesthost")
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 10))
        app.buttons["settings"].tap()
        let version = app.staticTexts["settings-version"]
        for _ in 0..<5 { if version.exists && version.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(version.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(version.label.contains("1.0.0"), version.label)
        XCTAssertTrue(version.label.contains("15"), version.label)
        capture(app, "settings-version-build-15")
    }
    private func launch(_ args: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.bshk.murmur.uitesthost")
        app.launchArguments = ["--compact-translation-sheet", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + args
        app.launch()
        XCTAssertTrue(app.buttons["compact-close"].waitForExistence(timeout: 8), app.debugDescription)
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let item = XCTAttachment(screenshot: app.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item)
    }
    func testShortResultCopyAndReplacement() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["compact-output"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["compact-output"].label, "Завтра пришлю бумаги.")
        capture(app, "compact-short-light")
        app.buttons["compact-copy"].tap()
        XCTAssertTrue(app.buttons["compact-copy"].label.contains("Copied"))
        app.buttons["replace-translation"].tap()
        XCTAssertEqual(app.staticTexts["compact-host-text"].label, "Завтра пришлю бумаги.")
    }
    func testLongResultScrollKeepsControlsVisible() {
        let app = launch(["--compact-long", "--compact-dark"])
        let output = app.staticTexts["compact-output"]
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        let scroll = app.scrollViews["compact-output-scroll"]
        XCTAssertLessThanOrEqual(scroll.frame.height, 320)
        let before = app.buttons["replace-translation"].frame
        capture(app, "compact-long-dark")
        scroll.swipeUp(); scroll.swipeUp()
        XCTAssertEqual(app.buttons["replace-translation"].frame, before)
        XCTAssertTrue(app.buttons["compact-share"].isHittable)
        XCTAssertTrue(app.buttons["compact-close"].isHittable)
    }
    func testEditRetranslatesAndCancelPreservesResult() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["compact-output"].waitForExistence(timeout: 5))
        app.buttons["compact-edit"].tap()
        let editor = app.textViews["compact-source-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText(" More text")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(app.staticTexts["compact-output"].label, "Завтра пришлю бумаги.")
        app.buttons["compact-edit"].tap()
        editor.tap(); editor.typeText(" More text")
        app.buttons["compact-apply-edit"].tap()
        XCTAssertTrue(app.staticTexts["compact-output"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["compact-output"].label.hasPrefix("Updated translation:"))
        capture(app, "compact-edited")
    }
    func testReadOnlyHidesReplaceAndCanShare() {
        let app = launch(["--compact-read-only", "--compact-dark"])
        XCTAssertTrue(app.staticTexts["compact-output"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["replace-translation"].exists)
        capture(app, "compact-read-only-dark")
        app.buttons["compact-share"].tap()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
    }
    func testCancelTranslationKeepsSourceAndCanClose() {
        let app = launch(["--compact-slow"])
        XCTAssertTrue(app.buttons["compact-cancel"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["compact-source-language"].isEnabled)
        capture(app, "compact-progress")
        app.buttons["compact-cancel"].tap()
        XCTAssertTrue(app.buttons["compact-translate"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["compact-original"].label, "Lähetän paperit huomenna.")
        app.buttons["compact-close"].tap()
        XCTAssertTrue(app.buttons["Show translation"].waitForExistence(timeout: 5))
    }
    func testErrorKeepsOriginalAndRetryAccessible() {
        let app = launch(["--compact-error"])
        XCTAssertTrue(app.buttons["compact-translate"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["compact-original"].label, "Lähetän paperit huomenna.")
        XCTAssertTrue(app.buttons["Details"].isHittable)
        capture(app, "compact-error")
        app.buttons["compact-translate"].tap()
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 5))
    }
    func testAccessibilityTextKeepsActionsReachable() {
        let app = launch(["--compact-accessibility"])
        XCTAssertTrue(app.staticTexts["compact-output"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["compact-close"].isHittable)
        XCTAssertTrue(app.buttons["replace-translation"].isHittable)
        capture(app, "compact-accessibility")
    }
}
