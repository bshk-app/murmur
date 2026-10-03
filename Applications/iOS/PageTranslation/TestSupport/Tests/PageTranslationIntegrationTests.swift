import XCTest

final class PageTranslationIntegrationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSelectedFinnishTextShowsProviderAndTranslation() throws {
        try checkSelectedTextTranslation(long: false)
    }

    func testSelectedFinnishNotesWithLinkTranslateToRussian() throws {
        try checkSelectedTextTranslation(long: true)
    }

    private func checkSelectedTextTranslation(long: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-fixture", "--selected-text-fixture", "-AppleLanguages", "(en)"]
        if long { app.launchArguments += ["--selected-text-long-fixture"] }
        app.launch()
        let status = app.staticTexts["page-fixture-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "READY:"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed, status.label)
        app.buttons["page-default-apps-settings"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        if !settings.navigationBars["Default Translation App"].exists {
            let translation = settings.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Translation")).firstMatch
            // Some simulator runtimes open the Settings root for the default-apps URL.
            if !translation.waitForExistence(timeout: 2) {
                let defaults = settings.buttons["com.apple.Settings.Apps.DefaultApps"]
                if !defaults.exists {
                    let apps = settings.buttons["com.apple.settings.apps"]
                    for _ in 0..<5 { if apps.exists && apps.isHittable { break }; settings.swipeUp() }
                    XCTAssertTrue(apps.exists, settings.debugDescription)
                    apps.tap()
                }
                XCTAssertTrue(defaults.waitForExistence(timeout: 5), settings.debugDescription)
                defaults.tap()
            }
            for _ in 0..<5 { if translation.exists && translation.isHittable { break }; settings.swipeUp() }
            XCTAssertTrue(translation.exists, settings.debugDescription)
            translation.tap()
        }
        let previous = settings.buttons.allElementsBoundByIndex.first(where: { $0.isSelected })?.label
        defer {
            settings.activate()
            if let previous, settings.buttons[previous].exists {
                settings.buttons[previous].tap()
                XCTAssertTrue(settings.buttons[previous].isSelected)
            }
        }
        let provider = settings.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Murmator")).firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 10), settings.debugDescription)
        provider.tap()
        app.activate()
        let editor = app.textViews["provider-fixture-text"]
        let source = try XCTUnwrap(editor.value as? String)
        let selectAll = app.menuItems["Select All"]
        func translateItem() -> XCUIElement {
            app.buttons["Translate"].exists ? app.buttons["Translate"] : app.menuItems["Translate"]
        }
        for _ in 0..<2 {
            editor.tap()
            editor.press(forDuration: 1.2)
            if selectAll.waitForExistence(timeout: 3) { selectAll.tap(); break }
            if translateItem().exists { break }
        }
        for _ in 0..<4 {
            if translateItem().exists { break }
            if app.buttons["Forward"].exists { app.buttons["Forward"].tap() }
        }
        XCTAssertTrue(translateItem().waitForExistence(timeout: 5), app.debugDescription)
        translateItem().tap()
        let shown = app.buttons["compact-source-language"].waitForExistence(timeout: 15)
        capture("selected-text-provider-presentation")
        XCTAssertTrue(shown, "Blank system translation sheet: " + app.debugDescription)
        XCTAssertEqual(app.staticTexts["compact-original"].label, source, "The provider must receive the entire selection")
        let result = app.staticTexts["compact-output"]
        XCTAssertTrue(result.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertFalse(result.label.isEmpty)
        XCTAssertNotEqual(result.label, "Tarkista ajankohtaiset rahoitusehdot")
        if long {
            XCTAssertTrue(result.label.range(of: "[А-Яа-я]", options: .regularExpression) != nil, result.label)
            // This fixture is shorter than the automatic expansion threshold.
            // Reproduce the user's full-height sheet by dragging its system title.
            let title = app.staticTexts["Murmator"]
            XCTAssertTrue(title.exists, app.debugDescription)
            title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
            let scroll = app.scrollViews["compact-output-scroll"]
            let fits = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                scroll.frame.height + 1 >= result.frame.height &&
                    app.buttons["compact-copy"].isHittable && app.buttons["compact-share"].isHittable
            }, object: nil)
            let fitResult = XCTWaiter.wait(for: [fits], timeout: 8)
            capture("selected-text-provider-layout")
            XCTAssertEqual(fitResult, .completed,
                "Reader: \(scroll.frame); text: \(result.frame). " + app.debugDescription)
        }
        print("SELECTED_TEXT_TRANSLATION: " + result.label)
        capture("selected-text-provider-result")
    }

    func testHUSSeparateWindowTranslatesToRussian() throws {
        try translateHUSPage("https://www.hus.fi/")
    }
    func testHUSFeedbackPageTranslatesToRussian() throws {
        try translateHUSPage("https://www.hus.fi/potilaalle/opas-potilaalle/oikeutesi-potilaana/anna-palautetta")
    }
    private func translateHUSPage(_ url: String) throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        let host = XCUIApplication()
        host.launchArguments = ["--test-fixture", "--fixture-page-url", url]
        host.launch()
        let status = host.staticTexts["page-fixture-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "READY:"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed)
        host.buttons["open-page-small"].tap()
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        try openAction(in: safari)
        let start = safari.buttons["page-translate-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), safari.debugDescription)
        safari.buttons["page-target"].tap()
        let russian = safari.descendants(matching: .any).matching(identifier: "Russian").firstMatch
        XCTAssertTrue(russian.waitForExistence(timeout: 5), safari.debugDescription)
        russian.tap()
        capture("hus-restored-separate-window")
        start.tap()
        XCTAssertTrue(safari.staticTexts["page-translation-progress"].waitForExistence(timeout: 15), safari.debugDescription)
        capture("hus-restored-window-progress")
        let restore = safari.descendants(matching: .any).matching(identifier: "Show original").firstMatch
        let failure = safari.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Translation failed.")).firstMatch
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in restore.exists || failure.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 180), .completed)
        XCTAssertFalse(failure.exists, failure.exists ? failure.label : "")
        XCTAssertTrue(restore.exists, safari.debugDescription)
        capture("hus-restored-window-complete")
    }

    func testFixtureOriginalCheck() throws {
        let safari = try openFixture(long: false)
        let verify = safari.buttons["Verify original page"]
        XCTAssertTrue(verify.waitForExistence(timeout: 5), safari.debugDescription)
        verify.tap()
        XCTAssertTrue(safari.staticTexts["PASS: unchanged"].waitForExistence(timeout: 10), safari.debugDescription)
    }

    func testReopenTranslatedPageUsesOriginalSource() throws {
        let safari = try openFixture(long: false)
        try openAction(in: safari)
        let start = safari.buttons["page-translate-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), safari.debugDescription)
        start.tap()
        XCTAssertTrue(safari.staticTexts["PASS: translated"].waitForExistence(timeout: 180), safari.debugDescription)
        try openAction(in: safari)
        let source = safari.buttons["page-source"]
        XCTAssertTrue(source.waitForExistence(timeout: 15), safari.debugDescription)
        XCTAssertTrue(source.label.contains("English") || String(describing: source.value).contains("English"), safari.debugDescription)
        let cancel = safari.buttons["page-translate-cancel"]
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10), safari.debugDescription)
        XCTAssertTrue(safari.staticTexts["PASS: translated"].exists, safari.debugDescription)
        // Also deliver fresh native output through a second invocation, so this
        // checks both cached preprocessing and result finalization across worlds.
        try openAction(in: safari)
        XCTAssertTrue(start.waitForExistence(timeout: 15), safari.debugDescription)
        start.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 90), safari.debugDescription)
        XCTAssertTrue(safari.staticTexts["PASS: translated"].exists, safari.debugDescription)
        toolbarToggle("Show original", in: safari).tap()
        XCTAssertTrue(safari.staticTexts["PASS: restored"].waitForExistence(timeout: 10), safari.debugDescription)
        capture("production-reopen-original-source-restored")
    }

    func testSmallPageTranslationRestoreAndClose() throws {
        let safari = try openFixture(long: false)
        try openAction(in: safari)
        let start = safari.buttons["page-translate-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), safari.debugDescription)
        XCTAssertTrue(start.isEnabled, safari.debugDescription)
        start.tap()
        XCTAssertTrue(safari.staticTexts["PASS: translated"].waitForExistence(timeout: 180), safari.debugDescription)
        capture("production-small-translated")
        let restore = toolbarToggle("Show original", in: safari)
        XCTAssertTrue(restore.waitForExistence(timeout: 5), safari.debugDescription)
        restore.tap()
        XCTAssertTrue(safari.staticTexts["PASS: restored"].waitForExistence(timeout: 10), safari.debugDescription)
        capture("production-small-restored")
        toolbarToggle("Show translation", in: safari).tap()
        XCTAssertTrue(safari.staticTexts["PASS: translated"].waitForExistence(timeout: 10), safari.debugDescription)
        safari.buttons["Close"].tap()
        XCTAssertTrue(safari.staticTexts["PASS: closed"].waitForExistence(timeout: 10), safari.debugDescription)
        capture("production-small-closed")
    }

    func testLongPageTranslationAndRestoration() throws {
        let safari = try openFixture(long: true)
        try openAction(in: safari)
        let start = safari.buttons["page-translate-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), safari.debugDescription)
        start.tap()
        XCTAssertTrue(safari.staticTexts["PASS: translated"].waitForExistence(timeout: 240), safari.debugDescription)
        capture("production-long-translated")
        toolbarToggle("Show original", in: safari).tap()
        XCTAssertTrue(safari.staticTexts["PASS: restored"].waitForExistence(timeout: 10), safari.debugDescription)
        capture("production-long-restored")
    }

    func testCancelBeforeTranslationLeavesPageOriginal() throws {
        let safari = try openFixture(long: false)
        try openAction(in: safari)
        let cancel = safari.buttons["page-translate-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), safari.debugDescription)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10), safari.debugDescription)
        XCTAssertTrue(safari.staticTexts["READY: Production page translation"].exists, safari.debugDescription)
        XCTAssertFalse(toolbarToggle("Show original", in: safari).exists)
        let verify = safari.buttons["Verify original page"]
        XCTAssertTrue(verify.waitForExistence(timeout: 5), safari.debugDescription)
        verify.tap()
        XCTAssertTrue(safari.staticTexts["PASS: unchanged"].waitForExistence(timeout: 10), safari.debugDescription)
        capture("production-cancelled")
    }

    func testCancelDuringTranslationAndRetry() throws {
        let safari = try openFixture(long: true)
        try openAction(in: safari)
        let start = safari.buttons["page-translate-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), safari.debugDescription)
        start.tap()
        let progress = safari.staticTexts["page-translation-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 15), safari.debugDescription)
        let translating = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "Translated "), object: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [translating], timeout: 30), .completed, safari.debugDescription)
        let cancel = safari.buttons["page-translate-cancel"]
        XCTAssertTrue(cancel.isEnabled, safari.debugDescription)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 45), safari.debugDescription)
        let verify = safari.buttons["Verify original page"]
        XCTAssertTrue(verify.waitForExistence(timeout: 5), safari.debugDescription)
        verify.tap()
        // Safari can finish removing the action sheet after its controls leave
        // accessibility. Retry the harmless fixture check if that tap was lost.
        if !safari.staticTexts["PASS: unchanged"].waitForExistence(timeout: 3) { verify.tap() }
        XCTAssertTrue(safari.staticTexts["PASS: unchanged"].waitForExistence(timeout: 10), safari.debugDescription)
        XCTAssertFalse(toolbarToggle("Show original", in: safari).exists)
        capture("production-cancelled-during-inference")

        // The same page must be reusable after cancellation releases the model.
        try openAction(in: safari)
        XCTAssertTrue(start.waitForExistence(timeout: 15), safari.debugDescription)
        XCTAssertTrue(start.isEnabled, safari.debugDescription)
        start.tap()
        XCTAssertTrue(safari.staticTexts["PASS: translated"].waitForExistence(timeout: 240), safari.debugDescription)
        capture("production-retry-after-cancel-translated")
    }

    private func openFixture(long: Bool) throws -> XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").terminate()
        let host = XCUIApplication()
        host.launchArguments = ["--test-fixture"]
        host.launch()
        let status = host.staticTexts["page-fixture-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15), host.debugDescription)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "READY:"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed, status.label)
        host.buttons[long ? "open-page-long" : "open-page-small"].tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(safari.staticTexts["READY: Production page translation"].waitForExistence(timeout: 30), safari.debugDescription)
        capture(long ? "production-long-before" : "production-small-before")
        return safari
    }

    private func openAction(in safari: XCUIApplication) throws {
        var share = safari.buttons["Share"]
        for _ in 0..<3 {
            if share.exists && share.isHittable { break }
            let more = safari.buttons["More"]
            if more.exists && more.isHittable { more.tap() }
            share = safari.buttons["Share"]
            if share.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(share.waitForExistence(timeout: 5), safari.debugDescription)
        share.tap()
        var action = safari.buttons["Murmator"]
        if !action.exists { action = safari.cells.containing(.staticText, identifier: "Murmator").firstMatch }
        for _ in 0..<6 {
            if action.exists && action.isHittable { break }
            safari.swipeUp()
            action = safari.buttons["Murmator"]
            if !action.exists { action = safari.cells.containing(.staticText, identifier: "Murmator").firstMatch }
        }
        XCTAssertTrue(action.waitForExistence(timeout: 5), safari.debugDescription)
        action.tap()
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func toolbarToggle(_ label: String, in safari: XCUIApplication) -> XCUIElement {
        // WebKit exposes a button with aria-pressed as an accessibility switch.
        let toggle = safari.switches[label]
        return toggle.exists ? toggle : safari.buttons[label]
    }
}
