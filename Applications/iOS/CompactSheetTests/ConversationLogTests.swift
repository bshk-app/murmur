import XCTest

final class ConversationLogTests: XCTestCase {
    func testReadingPositionStaysFixedWhileDraftAndNewUtterancesArrive() {
        let app = XCUIApplication(bundleIdentifier: "app.bshk.murmur.uitesthost")
        app.launchArguments = ["-longConversation", "live", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        let beginning = app.buttons["transcript-beginning"]
        XCTAssertTrue(beginning.waitForExistence(timeout: 10))
        beginning.tap()
        let reader = app.scrollViews["transcript-reader"]
        reader.swipeUp()
        let candidates = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "live-translation-utterance-")).allElementsBoundByIndex
        guard let candidate = candidates.first(where: { $0.frame.intersects(reader.frame) && $0.frame.height > 0 }) else {
            return XCTFail("No historical utterance is visible after scrolling")
        }
        let anchored = app.staticTexts[candidate.identifier]
        let y = anchored.frame.minY
        // The draft now continues the log below the reading position, so it is announced, not shown.
        XCTAssertTrue(app.staticTexts["transcript-unread"].waitForExistence(timeout: 6))
        // Let a draft revision and a settled utterance land below the anchor.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "live updates")], timeout: 3)
        XCTAssertTrue(anchored.frame.intersects(reader.frame))
        XCTAssertEqual(anchored.frame.minY, y, accuracy: 2, "New speech must not move the utterance being read")
        let evidence = XCTAttachment(screenshot: app.screenshot()); evidence.name = "stable-reading-position"; evidence.lifetime = .keepAlways
        add(evidence)
    }
}
