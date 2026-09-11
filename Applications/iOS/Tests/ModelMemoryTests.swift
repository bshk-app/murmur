import XCTest

final class ModelMemoryTests: XCTestCase {
    func test_ready_keyboard_can_unload_and_prepare_again() throws {
        guard ProcessInfo.processInfo.environment["MURMUR_MEMORY_TEST"] == "1" else { throw XCTSkip("Physical-device model lifecycle test disabled") }
        let app = XCUIApplication(bundleIdentifier: "app.bshk.murmur.ios")
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)"]
        app.launch()
        app.buttons["Keyboard"].tap()
        app.buttons["keyboard-enable"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["keyboard-ready"].waitForExistence(timeout: 180))
        app.buttons["Done"].tap()
        app.buttons["settings"].tap()
        app.buttons["Manage loaded models"].tap()
        let status = app.staticTexts["model-memory-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertEqual(status.label, "Models loaded")
        app.buttons["unload-models"].tap()
        let unloaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Models unloaded'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [unloaded], timeout: 30), .completed)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "models-unloaded"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Prepare dictation"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["keyboard-ready"].waitForExistence(timeout: 180))
        app.buttons["keyboard-disable"].tap()
    }
}
