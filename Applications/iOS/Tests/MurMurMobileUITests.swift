import XCTest

final class MurMurMobileUITests: XCTestCase {
    func test_onboarding_russian_layout_and_optional_setup() {
        let app = XCUIApplication()
        app.launchArguments = ["--onboarding-ui-testing", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-speechLanguage", "ru"]
        app.launch()
        let mascot = app.descendants(matching: .any)["onboarding-mascot"]
        XCTAssertTrue(mascot.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Просто скажи"].exists)
        let origin = mascot.frame
        for index in 0..<5 {
            XCTAssertEqual(mascot.frame.minY, origin.minY, accuracy: 1)
            XCTAssertEqual(mascot.frame.height, origin.height, accuracy: 1)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Onboarding-RU-\(index)"; screenshot.lifetime = .keepAlways; add(screenshot)
            XCTAssertTrue(app.buttons["onboarding-next"].isEnabled)
            if index == 2 { XCTAssertTrue(app.buttons["onboarding-languages"].exists) }
            app.buttons["onboarding-next"].tap()
        }
        XCTAssertTrue(app.buttons["record-note"].waitForExistence(timeout: 5))
    }

    func test_notes_search_detail_and_settings() {
        let app=XCUIApplication()
        app.launchArguments=["--ui-testing","-AppleLanguages","(en)","-AppleLocale","en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Notes"].waitForExistence(timeout:15))
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="Notes";screenshot.lifetime = .keepAlways;add(screenshot)
        let search=app.textFields["search-notes"];search.tap();search.typeText("tomorrow")
        app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","note-")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["note-text"].waitForExistence(timeout:5))
        let detail=XCTAttachment(screenshot:app.screenshot());detail.name="Note detail";detail.lifetime = .keepAlways;add(detail)
        app.buttons["copy-note"].tap();XCTAssertTrue(app.buttons["Copied"].exists || app.staticTexts["Copied"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout:5))
        let settings=XCTAttachment(screenshot:app.screenshot());settings.name="Settings";settings.lifetime = .keepAlways;add(settings)
    }
}
