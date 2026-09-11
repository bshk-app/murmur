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
        let draft = app.staticTexts["pending-utterance-text"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        let initialDraft = draft.label
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { value, _ in
            guard let element = value as? XCUIElement, element.exists else { return false }
            return element.label != initialDraft
        }, object: draft)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 6), .completed)
        XCTAssertTrue(app.staticTexts["transcript-unread"].waitForExistence(timeout: 6))
        XCTAssertTrue(anchored.frame.intersects(reader.frame))
        XCTAssertEqual(anchored.frame.minY, y, accuracy: 2, "New speech must not move the utterance being read")
        let evidence = XCTAttachment(screenshot: app.screenshot()); evidence.name = "stable-reading-position"; evidence.lifetime = .keepAlways
        add(evidence)
    }
}
