import XCTest

final class ProgressiveSafariTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testHUSActivationFromSafariPageMenu() throws {
        XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").terminate()
        let host = try startHost(["--fixture-page-url", "https://www.hus.fi/"])
        host.buttons["open-page-small"].tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        let pageMenu = safari.buttons["PageFormatMenuButton"]
        XCTAssertTrue(pageMenu.waitForExistence(timeout: 15), safari.debugDescription)
        pageMenu.tap()
        // Installing a newly signed test host may reset extension enablement.
        let manage = safari.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Manage Extensions")).firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 10), safari.debugDescription)
        manage.tap()
        let enabled = safari.switches["Murmator"].firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout: 10), safari.debugDescription)
        if enabled.value as? String == "0" {
            let control = safari.switches.matching(identifier: "Murmator").allElementsBoundByIndex.first(where: { $0.frame.width < 100 }) ?? enabled
            control.tap()
            let switchedOn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: enabled)
            XCTAssertEqual(XCTWaiter.wait(for: [switchedOn], timeout: 8), .completed)
        }
        safari.buttons["Done"].tap()
        // Safari can return directly to the already-open page menu.
        if !manage.exists || !manage.isHittable { pageMenu.tap() }
        capture("hus-safari-page-menu")
        let action = safari.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Murmator")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10), safari.debugDescription)
        action.tap()
        let allow = safari.buttons["Allow for One Day"]
        if allow.waitForExistence(timeout: 8) { capture("hus-safari-site-permission"); allow.tap() }
        let close = safari.buttons["Close and restore original"]
        XCTAssertTrue(close.waitForExistence(timeout: 20), safari.debugDescription)
        XCTAssertTrue(safari.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Translated into ")).firstMatch.waitForExistence(timeout: 120), safari.debugDescription)
        capture("hus-translated-from-page-menu")
        close.tap()
        XCTAssertFalse(safari.buttons["Close and restore original"].exists)
    }

    func testHUSSetupBannerCanClose() throws {
        let host = try startHost(["--fixture-page-url", "https://www.hus.fi/"])
        host.buttons["open-page-small"].tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        let essentialCookies = safari.buttons["Salli vain välttämättömät evästeet"]
        if essentialCookies.waitForExistence(timeout: 10) { essentialCookies.tap() }
        XCTAssertTrue(safari.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Vaikuttavinta")).firstMatch.waitForExistence(timeout: 45), safari.debugDescription)
        try share(in: safari)
        let setup = safari.links["Open Murmator"]
        XCTAssertTrue(setup.waitForExistence(timeout: 15), safari.debugDescription)
        capture("hus-setup-before-close")
        let close = safari.webViews.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), safari.debugDescription)
        close.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: setup)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed, "HUS setup banner must close after Share has ended")
        capture("hus-setup-after-close")
    }

    func testShareSetupBannerCanCloseWithoutWebsitePermission() throws {
        // localhost is distinct from the previously allowed 127.0.0.1 fixture.
        let safari = try openPage(long: false, args: ["--fixture-server", "http://localhost:18765"])
        try share(in: safari)
        let setup = safari.links["Open Murmator"]
        XCTAssertTrue(setup.waitForExistence(timeout: 15), safari.debugDescription)
        capture("setup-before-close")
        let close = safari.webViews.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), safari.debugDescription)
        close.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: setup)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed, "Share setup banner must close after the Share action has ended")
        capture("setup-after-close")
    }

    func testSetupExtension() throws {
        let host = try startHost()
        host.buttons["page-safari-settings"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15))
        print("SAFARI SETTINGS\n" + settings.debugDescription)
        let toggle = settings.switches["Allow Extension"]
        if toggle.waitForExistence(timeout: 5), toggle.value as? String == "0" { toggle.tap() }
        print("ENABLED SETTINGS\n" + settings.debugDescription)
        capture("safari-extension-settings")
    }

    func testShareReturnsToPageAndTranslates() throws {
        let safari = try openPage(long: true)
        try share(in: safari)
        let close = safari.buttons["Close and restore original"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), safari.debugDescription)
        XCTAssertFalse(safari.buttons["page-translate-start"].exists)
        XCTAssertTrue(safari.staticTexts["PASS: partial"].waitForExistence(timeout: 90), safari.debugDescription)
        capture("progressive-share-partial")
        XCTAssertTrue(safari.staticTexts["PASS: translated"].waitForExistence(timeout: 240), safari.debugDescription)
        capture("progressive-share-complete")
        toggle("Original", in: safari).tap()
        XCTAssertTrue(safari.staticTexts["PASS: original"].waitForExistence(timeout: 8), safari.debugDescription)
        capture("progressive-original")
        toggle("Translation", in: safari).tap()
        XCTAssertTrue(safari.staticTexts["PASS: translated"].waitForExistence(timeout: 8), safari.debugDescription)
        close.tap()
        XCTAssertTrue(safari.staticTexts["PASS: closed"].waitForExistence(timeout: 8), safari.debugDescription)
        capture("progressive-closed")
    }

    func testStopMutationAndReentry() throws {
        let safari = try openPage(long: true)
        try share(in: safari)
        XCTAssertTrue(safari.staticTexts["PASS: partial"].waitForExistence(timeout: 90))
        safari.buttons["Stop"].tap()
        XCTAssertTrue(safari.staticTexts["PASS: stopped"].waitForExistence(timeout: 10), safari.debugDescription)
        capture("progressive-stopped")
        try share(in: safari)
        XCTAssertTrue(safari.staticTexts["PASS: translated"].waitForExistence(timeout: 120), safari.debugDescription)
        safari.buttons["Edit page externally"].tap()
        safari.buttons["Close and restore original"].tap()
        XCTAssertTrue(safari.staticTexts["PASS: closed"].waitForExistence(timeout: 10), safari.debugDescription)
        capture("progressive-reentry-restored")
    }

    func testFinnishPageLanguageControls() throws {
        let safari = try openPage(long: false, args: ["--fixture-finnish"])
        try share(in: safari)
        XCTAssertTrue(safari.buttons["Close and restore original"].waitForExistence(timeout: 15))
        XCTAssertTrue(safari.staticTexts["PASS: translated"].waitForExistence(timeout: 120), safari.debugDescription)
        capture("progressive-finnish-before-language-change")
        safari.otherElements["To"].tap()
        print("LANGUAGE MENU\n" + safari.debugDescription)
        let russian = safari.descendants(matching: .any).matching(identifier: "Russian").firstMatch
        XCTAssertTrue(russian.waitForExistence(timeout: 5), safari.debugDescription)
        russian.tap()
        XCTAssertTrue(safari.staticTexts["Translated into Russian"].waitForExistence(timeout: 120), safari.debugDescription)
        XCTAssertTrue(safari.staticTexts["PASS: translated"].exists)
        capture("progressive-finnish-to-russian")
        toggle("Original", in: safari).tap()
        XCTAssertTrue(safari.staticTexts["PASS: original"].waitForExistence(timeout: 5))
        safari.buttons["Close and restore original"].tap()
        XCTAssertTrue(safari.staticTexts["PASS: closed"].waitForExistence(timeout: 5))
    }

    private func startHost(_ args: [String] = []) throws -> XCUIApplication {
        let host = XCUIApplication()
        host.launchArguments = ["--test-fixture", "-AppleLanguages", "(en)"] + args
        host.launch()
        let status = host.staticTexts["page-fixture-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15), host.debugDescription)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "READY:"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed, status.label)
        return host
    }
    private func openPage(long: Bool, args: [String] = []) throws -> XCUIApplication {
        let host = try startHost(args)
        host.buttons[long ? "open-page-long" : "open-page-small"].tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(safari.staticTexts["READY: Progressive Safari fixture"].waitForExistence(timeout: 30), safari.debugDescription)
        return safari
    }
    private func share(in safari: XCUIApplication) throws {
        var button = safari.buttons["Share"]
        for _ in 0..<3 {
            if button.exists && button.isHittable { break }
            if safari.buttons["More"].exists { safari.buttons["More"].tap() }
            button = safari.buttons["Share"]
            if button.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), safari.debugDescription); button.tap()
        var action = safari.buttons["Murmator"]
        if !action.exists { action = safari.cells.containing(.staticText, identifier: "Murmator").firstMatch }
        for _ in 0..<6 {
            if action.exists && action.isHittable { break }
            safari.swipeUp()
        }
        XCTAssertTrue(action.waitForExistence(timeout: 5), safari.debugDescription); action.tap()
    }
    private func toggle(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.switches[name].exists ? app.switches[name] : app.buttons[name]
    }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
