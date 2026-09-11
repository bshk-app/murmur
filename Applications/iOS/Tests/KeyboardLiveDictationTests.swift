import XCTest
import AVFoundation

final class KeyboardLiveDictationTests: XCTestCase {
    func test_preparation_continues_after_returning_to_keyboard() throws {
        guard ProcessInfo.processInfo.environment["MURMUR_ENABLE_SYNC_TEST"] == "1" else { throw XCTSkip("Device preparation transition test disabled") }
        let main = XCUIApplication(bundleIdentifier: "app.bshk.murmur.ios")
        let host = XCUIApplication(bundleIdentifier: "app.bshk.murmur.uitesthost")
        main.launchArguments = ["--debug-enable-sync-delay", "-AppleLanguages", "(en)"]
        main.launch()
        host.launchArguments = ["--keyboard-host-probe", "-AppleLanguages", "(en)"]
        host.launch()
        addTeardownBlock { main.terminate(); host.activate() }
        let field = host.descendants(matching: .any)["keyboard-probe-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); selectKeyboard(host)
        let open = host.descendants(matching: .any)["keyboard-open-murmur"]
        XCTAssertTrue(open.waitForExistence(timeout: 8)); open.tap()
        XCTAssertTrue(main.descendants(matching: .any)["keyboard-preparing"].waitForExistence(timeout: 8))
        host.activate(); field.tap()
        XCTAssertFalse(open.isHittable, "Preparation must not ask to enable the microphone again")
        let hold = host.buttons["keyboard-hold-to-talk"]
        XCTAssertTrue(hold.waitForExistence(timeout: 180), "Returning to the keyboard during preparation must not cancel the session")
        XCTAssertFalse(open.isHittable)
        let source = host.buttons["keyboard-source-language"]
        let currentLanguage = source.label.components(separatedBy: ":").last!.trimmingCharacters(in: .whitespaces)
        source.tap()
        let sameLanguage = host.descendants(matching: .any).matching(NSPredicate(format: "label == %@", currentLanguage)).firstMatch
        for _ in 0..<5 where !sameLanguage.exists { host.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(sameLanguage.waitForExistence(timeout: 5)); sameLanguage.tap()
        let settled = XCTestExpectation(description: "Allow command polling after unchanged language selection")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        XCTWaiter().wait(for: [settled], timeout: 2)
        XCTAssertTrue(hold.isHittable); XCTAssertFalse(open.isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "ready-after-background-preparation"; shot.lifetime = .keepAlways; add(shot)
        if host.buttons["keyboard-end-session"].exists { host.buttons["keyboard-end-session"].tap() }
    }
    func test_prepare_for_manual_voice() throws {
        guard ProcessInfo.processInfo.environment["MURMUR_MANUAL_KEYBOARD_TEST"] == "1" else { throw XCTSkip("Manual voice preparation disabled") }
        let main = XCUIApplication(bundleIdentifier: "app.bshk.murmur.ios")
        let host = XCUIApplication(bundleIdentifier: "app.bshk.murmur.uitesthost")
        main.terminate()
        host.launchArguments = ["--keyboard-host-probe", "-AppleLanguages", "(en)"]
        host.launch()
        let field = host.descendants(matching: .any)["keyboard-probe-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); selectKeyboard(host)
        let open = host.descendants(matching: .any)["keyboard-open-murmur"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(main.wait(for: .runningForeground, timeout: 8))
        XCTAssertTrue(main.descendants(matching: .any)["keyboard-ready"].waitForExistence(timeout: 120))
        host.activate(); field.tap()
        XCTAssertTrue(host.buttons["keyboard-hold-to-talk"].waitForExistence(timeout: 8))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "keyboard-ready-for-human-voice"; shot.lifetime = .keepAlways; add(shot)
    }
    func test_live_microphone_hold_translate_insert_delete_and_send() throws {
        guard ProcessInfo.processInfo.environment["MURMUR_LIVE_KEYBOARD_TEST"] == "1" else { throw XCTSkip("Physical acoustic keyboard test disabled") }
        let main = XCUIApplication(bundleIdentifier: "app.bshk.murmur.ios")
        let host = XCUIApplication(bundleIdentifier: "app.bshk.murmur.uitesthost")
        main.terminate()
        host.launchArguments = ["--keyboard-host-probe", "--keyboard-acoustic-fixture", "-AppleLanguages", "(en)"]
        host.launch()
        addTeardownBlock { main.terminate(); host.activate() }
        let field = host.descendants(matching: .any)["keyboard-probe-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        selectKeyboard(host)
        XCTAssertFalse(host.buttons["Insert latest note"].exists)
        host.buttons["keyboard-source-language"].tap()
        let russian = host.descendants(matching: .any).matching(NSPredicate(format: "label == 'Russian' OR label == 'Русский'")).firstMatch
        for _ in 0..<5 where !russian.exists { host.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(russian.waitForExistence(timeout: 5)); russian.tap()
        host.buttons["keyboard-translation-language"].tap()
        let english = host.descendants(matching: .any).matching(NSPredicate(format: "label == '→ English' OR label == '→ Английский'")).firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 5)); english.tap()
        let open = host.descendants(matching: .any)["keyboard-open-murmur"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(main.wait(for: .runningForeground, timeout: 8))
        XCTAssertTrue(main.descendants(matching: .any)["keyboard-ready"].waitForExistence(timeout: 240))
        host.activate()
        field.tap()
        let hold = host.buttons["keyboard-hold-to-talk"]
        XCTAssertTrue(hold.waitForExistence(timeout: 8))
        let volume = host.sliders.firstMatch
        XCTAssertTrue(volume.waitForExistence(timeout: 5))
        let originalVolume = AVAudioSession.sharedInstance().outputVolume
        volume.adjust(toNormalizedSliderPosition: 0.55)
        addTeardownBlock { if host.state != .notRunning { host.activate(); if volume.exists { volume.adjust(toNormalizedSliderPosition: CGFloat(originalVolume)) } } }
        host.buttons["keyboard-play-fixture"].tap()
        XCTAssertEqual(main.state, .runningBackground)
        hold.press(forDuration: 13)
        XCTAssertEqual(main.state, .runningBackground)
        let translated = NSPredicate { _, _ in
            let value = (field.value as? String ?? "").lowercased()
            return value.contains("communication") || value.contains("channels")
        }
        expectation(for: translated, evaluatedWith: field)
        waitForExpectations(timeout: 40)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "live-microphone-translation-inserted"; shot.lifetime = .keepAlways; add(shot)
        let before = field.value as? String ?? ""
        host.buttons["keyboard-delete"].tap()
        let after = field.value as? String ?? ""
        XCTAssertEqual(after.count, max(0, before.count - 1))
        host.buttons["keyboard-send"].tap()
        XCTAssertTrue(host.staticTexts["Local send count: 1"].waitForExistence(timeout: 5))
        host.buttons["keyboard-end-session"].tap()
        XCTAssertTrue(host.descendants(matching: .any)["keyboard-open-murmur"].waitForExistence(timeout: 10))
    }
    private func selectKeyboard(_ host: XCUIApplication) {
        if host.buttons["keyboard-source-language"].waitForExistence(timeout: 2) { return }
        let globe = host.buttons["Next keyboard"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5)); globe.press(forDuration: 1)
        let option = host.descendants(matching: .any).matching(NSPredicate(format: "label == 'MurMur'")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
        XCTAssertTrue(host.buttons["keyboard-source-language"].waitForExistence(timeout: 5))
    }
}
