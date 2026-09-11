import XCTest

/// Device-only diagnostic. It records both outcomes rather than requiring a particular undocumented behavior.
final class KeyboardNavigationTests: XCTestCase {
    func test_keyboard_controls_background_session() throws {
        guard ProcessInfo.processInfo.environment["MURMUR_KEYBOARD_PROBE"] == "1" else { throw XCTSkip("Device probe disabled") }
        let host = XCUIApplication(bundleIdentifier: "app.bshk.murmur.uitesthost")
        host.launchArguments = ["--keyboard-host-probe"]
        host.launch()
        let field = host.descendants(matching: .any)["keyboard-probe-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        try selectMurMur(in: host, probe: "probe-context-open")
        tapProbe(in: host, id: "probe-context-open", y: 0.674)
        for _ in 0..<30 {
            if (field.value as? String ?? "").contains("communication channels") { break }
            tapProbe(in: host, id: "probe-insert-result", y: 0.623)
            let tick = XCTestExpectation(description: "Wait for background result")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick.fulfill() }
            XCTWaiter().wait(for: [tick], timeout: 2)
        }
        XCTAssertTrue((field.value as? String ?? "").contains("communication channels"))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "keyboard-command-and-translation"; shot.lifetime = .keepAlways; add(shot)
    }

    func test_keyboard_inserts_background_translation() throws {
        guard ProcessInfo.processInfo.environment["MURMUR_KEYBOARD_PROBE"] == "1" else { throw XCTSkip("Device probe disabled") }
        let host = XCUIApplication(bundleIdentifier: "app.bshk.murmur.uitesthost")
        host.launchArguments = ["--keyboard-host-probe"]
        host.launch()
        let field = host.descendants(matching: .any)["keyboard-probe-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        try selectMurMur(in: host, probe: "probe-insert-result")
        tapProbe(in: host, id: "probe-insert-result", y: 0.623)
        let inserted = NSPredicate { _, _ in (field.value as? String ?? "").contains("communication channels") }
        expectation(for: inserted, evaluatedWith: field)
        waitForExpectations(timeout: 5)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "keyboard-inserted-background-translation"; shot.lifetime = .keepAlways; add(shot)
    }

    func test_keyboard_public_navigation_routes() throws {
        guard ProcessInfo.processInfo.environment["MURMUR_KEYBOARD_PROBE"] == "1" else { throw XCTSkip("Set TEST_RUNNER_MURMUR_KEYBOARD_PROBE=1 for the device navigation probe") }
        let host = XCUIApplication(bundleIdentifier: "app.bshk.murmur.uitesthost")
        let main = XCUIApplication(bundleIdentifier: "app.bshk.murmur.ios")
        host.launchArguments = ["--keyboard-host-probe"]
        host.launch()
        XCTAssertTrue(host.descendants(matching: .any)["keyboard-probe-input"].waitForExistence(timeout: 10))
        try selectMurMur(in: host, probe: "probe-context-open")
        tapProbe(in: host, id: "probe-context-open", y: 0.674)
        let contextOpened = main.wait(for: .runningForeground, timeout: 5)
        let contextShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        contextShot.name = "keyboard-context-open"; contextShot.lifetime = .keepAlways; add(contextShot)
        host.activate()
        if !host.buttons["probe-swiftui-link"].exists { host.descendants(matching: .any)["keyboard-probe-input"].tap() }
        tapProbe(in: host, id: "probe-swiftui-link", y: 0.735)
        let linkOpened = main.wait(for: .runningForeground, timeout: 5)
        let linkShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        linkShot.name = "keyboard-swiftui-link"; linkShot.lifetime = .keepAlways; add(linkShot)
        host.activate()
        if !host.buttons["probe-app-intent"].exists { host.descendants(matching: .any)["keyboard-probe-input"].tap() }
        tapProbe(in: host, id: "probe-app-intent", y: 0.802)
        let intentOpened = main.wait(for: .runningForeground, timeout: 5)
        let intentShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        intentShot.name = "keyboard-app-intent"; intentShot.lifetime = .keepAlways; add(intentShot)
        let result = XCTAttachment(string: "contextOpened=\(contextOpened)\nswiftUILinkOpened=\(linkOpened)\nappIntentOpened=\(intentOpened)")
        result.name = "keyboard-navigation-result"; result.lifetime = .keepAlways; add(result)
        XCTAssertTrue(contextOpened || linkOpened || intentOpened, "No tested public keyboard navigation route opened the containing app")
    }

    private func selectMurMur(in host: XCUIApplication, probe: String) throws {
        if host.buttons[probe].waitForExistence(timeout: 2) { return }
        let globe = host.buttons["Next keyboard"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5))
        globe.press(forDuration: 1)
        let menu = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        menu.name = "keyboard-picker"; menu.lifetime = .keepAlways; add(menu)
        let option = host.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "MurMur")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), host.debugDescription)
        option.tap()
        let selected = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        selected.name = "keyboard-selected"; selected.lifetime = .keepAlways; add(selected)
    }

    private func tapProbe(in host: XCUIApplication, id: String, y: CGFloat) {
        if host.buttons[id].exists { host.buttons[id].tap(); return }
        // This iOS build omits remote keyboard controls from the host's AX tree.
        // Coordinates come from the captured iPhone 15 Pro probe screen; actual
        // insertion / foreground transitions are asserted after each real tap.
        host.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)).tap()
    }
}
