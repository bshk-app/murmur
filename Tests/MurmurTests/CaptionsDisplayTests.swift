import AppKit
import XCTest
@testable import Murmur

/// The saved display must win over the cursor, and a saved display that is
/// not connected must still put the captions on a screen that exists — the
/// talk cannot stop because the projector was plugged into another port.
@MainActor
final class CaptionsDisplayTests: XCTestCase {
    func testEveryConnectedScreenHasAStableUUID() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let uuid = try XCTUnwrap(CaptionsDisplay.uuid(of: screen))
        XCTAssertEqual(CaptionsDisplay.uuid(of: screen), uuid)
        XCTAssertEqual(CaptionsDisplay.screen(for: uuid), screen)
    }

    func testEachPinnedScreenResolvesToItself() {
        for screen in NSScreen.screens {
            guard let uuid = CaptionsDisplay.uuid(of: screen) else { return XCTFail("no UUID for \(screen)") }
            XCTAssertEqual(CaptionsDisplay.resolve(uuid), screen)
        }
    }

    func testADisconnectedDisplayFallsBackToAConnectedOne() throws {
        let missing = UUID().uuidString
        XCTAssertNil(CaptionsDisplay.screen(for: missing))
        let fallback = try XCTUnwrap(CaptionsDisplay.resolve(missing))
        XCTAssertTrue(NSScreen.screens.contains(fallback))
        XCTAssertEqual(fallback, NSScreen.underCursor)
    }

    /// The band is sized from the screen it lands on and sits inside its
    /// visible area, clear of the bottom edge.
    func testTheBandIsPlacedAndSizedOnThePinnedScreen() throws {
        let overlay = CaptionsOverlay(defaults: UserDefaults(suiteName: "CaptionsTests.\(UUID().uuidString)")!)
        for screen in NSScreen.screens {
            let uuid = try XCTUnwrap(CaptionsDisplay.uuid(of: screen))
            overlay.begin(target: "", display: uuid)
            let frame = try XCTUnwrap(overlay.panelFrame)
            let expected = CaptionsLayout(screen: screen.frame.size, translating: false)
            XCTAssertEqual(overlay.model.layout, expected)
            XCTAssertEqual(frame.size, expected.bandSize)
            XCTAssertTrue(screen.visibleFrame.contains(frame), "\(frame) not inside \(screen.visibleFrame)")
            XCTAssertEqual(frame.minY, screen.visibleFrame.minY + expected.bottomInset)
        }
    }

    func testTurningTranslationOnMidTalkKeepsTheBandCompact() throws {
        let overlay = CaptionsOverlay(defaults: UserDefaults(suiteName: "CaptionsTests.\(UUID().uuidString)")!)
        overlay.begin(target: "", display: CaptionsDisplay.followCursor)
        let plain = try XCTUnwrap(overlay.panelFrame)
        overlay.setTranslationTarget("EN")
        let translating = try XCTUnwrap(overlay.panelFrame)
        XCTAssertEqual(overlay.model.layout.translationLines, 3)
        XCTAssertGreaterThan(translating.height, plain.height)
        let screen = try XCTUnwrap(CaptionsDisplay.resolve(CaptionsDisplay.followCursor))
        XCTAssertLessThan(translating.height, screen.frame.height * 0.30)
        XCTAssertEqual(translating.minY, plain.minY, "changing tracks must preserve the bottom edge")
    }

    /// Stop and start again inside the fade: the old fade's completion must
    /// not hide the new talk's band.
    func testARestartDuringTheFadeOutKeepsTheNewBandOnScreen() {
        let overlay = CaptionsOverlay(defaults: UserDefaults(suiteName: "CaptionsTests.\(UUID().uuidString)")!)
        overlay.begin(target: "", display: CaptionsDisplay.followCursor)
        overlay.dismiss()
        overlay.begin(target: "", display: CaptionsDisplay.followCursor)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(overlay.isVisible)
    }
}

/// Three lines of context per language without covering the presentation.
final class CaptionsLayoutTests: XCTestCase {
    func testA1080pScreenGetsSmallerTypeAndThreeLines() {
        let layout = CaptionsLayout(screen: CGSize(width: 1920, height: 1080), translating: false)
        XCTAssertEqual(layout.fontSize, 25)
        XCTAssertEqual(layout.bandWidth, 1536)
        XCTAssertEqual(layout.transcriptLines, 3)
        XCTAssertEqual(layout.translationLines, 0)
        XCTAssertEqual(layout.bottomInset, 54)
    }

    func testTypeIsClampedOnTinyAndHugeScreens() {
        XCTAssertEqual(CaptionsLayout(screen: CGSize(width: 800, height: 400), translating: false).fontSize, 14)
        XCTAssertEqual(CaptionsLayout(screen: CGSize(width: 7680, height: 4320), translating: false).fontSize, 48)
    }

    func testTranslationHasThreeLinesWithoutTakingLinesFromTheSource() {
        let plain = CaptionsLayout(screen: CGSize(width: 1920, height: 1080), translating: false)
        let translating = CaptionsLayout(screen: CGSize(width: 1920, height: 1080), translating: true)
        XCTAssertEqual(translating.transcriptLines, 3)
        XCTAssertEqual(translating.translationLines, 3)
        XCTAssertGreaterThan(translating.bandSize.height, plain.bandSize.height)
        XCTAssertLessThan(translating.bandSize.height, 1080 * 0.20, "the band must leave the slide visible")
    }

    func testTheTrackIsExactlyItsLines() {
        let one = CaptionsLayout.trackHeight(lines: 1, size: 60)
        let three = CaptionsLayout.trackHeight(lines: 3, size: 60)
        XCTAssertEqual(three, one * 3 + CaptionsLayout.lineSpacing(60) * 2)
    }
}

/// Exercise the actual TextKit layout and animated viewport, not a second
/// implementation of wrapping or a test of animation constants.
@MainActor
final class CaptionsScrollingTests: XCTestCase {
    private func makeView(lines: Int = 2) -> CaptionsTextView {
        let height = CaptionsLayout.trackHeight(lines: lines, size: 30)
        let view = CaptionsTextView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        view.reduceMotion = true
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func lines(in view: CaptionsTextView) -> [String] {
        let manager = view.textView.layoutManager!
        let container = view.textView.textContainer!
        manager.ensureLayout(for: container)
        var lines: [String] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, range, _ in
            let chars = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            lines.append((view.textView.string as NSString).substring(with: chars))
        }
        return lines
    }

    func testAddingWordsDoesNotRewrapExistingCompleteLines() {
        let overlay = CaptionsOverlay(defaults: UserDefaults(suiteName: "CaptionsTests.\(UUID().uuidString)")!)
        let view = makeView()
        var text = (0..<150).map { "слово\($0)" }.joined(separator: " ")
        overlay.update(confirmed: text, partial: "")
        view.update(confirmed: overlay.model.confirmed, partial: overlay.model.partial, size: 30, color: .white)
        let original = Array(lines(in: view).dropLast())
        for word in ["добавление", "ещё", "несколько", "новых", "слов"] {
            text += " " + word
            overlay.update(confirmed: text, partial: "")
            view.update(confirmed: overlay.model.confirmed, partial: overlay.model.partial, size: 30, color: .white)
            XCTAssertEqual(Array(lines(in: view).prefix(original.count)), original)
        }
    }

    func testTranslationKeepsItsLineBreaksWhenAnotherSentenceArrives() {
        let overlay = CaptionsOverlay(defaults: UserDefaults(suiteName: "CaptionsTests.\(UUID().uuidString)")!)
        let view = makeView(lines: 1)
        let text = String(repeating: "A translated sentence stays in place. ", count: 20)
        overlay.showTranslation(text)
        view.update(confirmed: overlay.model.translation, partial: "", size: 30, color: .yellow)
        let original = Array(lines(in: view).dropLast())
        overlay.showTranslation(text + "The next sentence.")
        view.update(confirmed: overlay.model.translation, partial: "", size: 30, color: .yellow)
        XCTAssertEqual(Array(lines(in: view).prefix(original.count)), original)
    }

    func testDraftPromotionChangesColorWithoutMovingText() throws {
        let view = makeView()
        let confirmed = "Привет 👩🏽‍💻"
        let partial = "мир é"
        view.update(confirmed: confirmed, partial: partial, size: 30, color: .white)
        let before = lines(in: view)
        let position = view.clipView.bounds.origin
        let index = (confirmed as NSString).length + 1
        let draft = try XCTUnwrap(view.textView.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(draft.alphaComponent, 0.72, accuracy: 0.001)
        view.update(confirmed: confirmed + " " + partial, partial: "", size: 30, color: .white)
        XCTAssertEqual(lines(in: view), before)
        XCTAssertEqual(view.clipView.bounds.origin, position)
        let final = try XCTUnwrap(view.textView.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(final.alphaComponent, 1)
        view.update(confirmed: confirmed, partial: "мир 👨‍👩‍👧‍👦", size: 30, color: .white)
        XCTAssertEqual(view.textView.string, confirmed + " мир 👨‍👩‍👧‍👦")
        for partial in ["e\u{301}", "é", "e", "e\u{301}", "👩", "👩🏽‍💻"] {
            view.update(confirmed: confirmed, partial: partial, size: 30, color: .white)
            XCTAssertEqual(Array(view.textView.string.utf16), Array((confirmed + " " + partial).utf16))
        }
    }

    func testAccurateCorrectionsPreserveMatchingTextAndTheNewerFastDraft() throws {
        let view = makeView(lines: 3)
        let draft = "этот мальчик показывает как работает приложение и потом включает перевод"
        let accurate = "Этот мальчик показывает, как работает приложение, и затем включает перевод."
        let newerDraft = "Дальше мы проверяем субтитры"
        view.update(confirmed: draft, partial: newerDraft, size: 25, color: .white)
        let storage = try XCTUnwrap(view.textView.textStorage)
        let anchor = NSAttributedString.Key("test.readingAnchor")
        for phrase in ["работает приложение", newerDraft] {
            storage.addAttribute(anchor, value: phrase, range: (storage.string as NSString).range(of: phrase))
        }
        view.update(confirmed: accurate, partial: newerDraft, size: 25, color: .white)
        XCTAssertEqual(storage.string, accurate + " " + newerDraft)
        for phrase in ["работает приложение", newerDraft] {
            let range = (storage.string as NSString).range(of: phrase)
            XCTAssertEqual(storage.attribute(anchor, at: range.location, effectiveRange: nil) as? String, phrase,
                           "matching text must survive in storage, not be deleted and reinserted")
        }
        let draftStart = (storage.string as NSString).range(of: newerDraft).location
        let color = try XCTUnwrap(storage.attribute(.foregroundColor, at: draftStart, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(color.alphaComponent, 0.72, accuracy: 0.001)
    }

    func testOverflowScrollsThroughIntermediatePositions() {
        let view = makeView()
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.reduceMotion = false
        view.update(confirmed: "Первая строка", partial: "", size: 30, color: .white)
        let before = view.clipView.bounds.minY
        let text = (0..<40).map { "слово\($0)" }.joined(separator: " ")
        view.update(confirmed: text, partial: "", size: 30, color: .white)
        let destination = view.textView.frame.height - view.bounds.height
        XCTAssertGreaterThan(destination, before)
        XCTAssertEqual(view.clipView.bounds.minY, before, accuracy: 0.5, "must not jump directly to the destination")
        var intermediate = false
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let y = view.clipView.bounds.minY
            if y > before + 0.5 && y < destination - 0.5 { intermediate = true }
        }
        XCTAssertTrue(intermediate, "the visible viewport must move smoothly")
        XCTAssertEqual(view.clipView.bounds.minY, destination, accuracy: 0.5)
    }

    func testReducedMotionResizeAndClearKeepTheLatestTextVisible() {
        let view = makeView()
        let text = String(repeating: "Длинный текст с переносами. ", count: 80)
        view.update(confirmed: text, partial: "", size: 30, color: .white)
        XCTAssertEqual(view.clipView.bounds.maxY, view.textView.frame.height, accuracy: 0.5)
        view.setFrameSize(CGSize(width: 400, height: view.frame.height))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.clipView.bounds.maxY, view.textView.frame.height, accuracy: 0.5)
        view.update(confirmed: "", partial: "", size: 30, color: .white)
        XCTAssertEqual(view.clipView.bounds.minY, 0)
        XCTAssertEqual(view.textView.string, "…")
    }

    func testAShorterCorrectionDoesNotClampTheViewportBeforeAnimating() {
        let view = makeView()
        let text = String(repeating: "Длинный черновик распознавания. ", count: 30)
        view.update(confirmed: "Начало.", partial: text, size: 30, color: .white)
        let before = view.clipView.bounds.minY
        view.reduceMotion = false
        view.update(confirmed: "Начало.", partial: String(text.prefix(text.count - 150)), size: 30, color: .white)
        XCTAssertEqual(view.clipView.bounds.minY, before, accuracy: 0.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertLessThan(view.clipView.bounds.minY, before)
        XCTAssertEqual(view.clipView.bounds.maxY, view.textView.frame.height, accuracy: 0.5)

        // A restart must cancel the earlier movement, including its completion.
        view.update(confirmed: "Начало.", partial: text, size: 30, color: .white)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.update(confirmed: "", partial: "", size: 30, color: .white)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(view.clipView.bounds.minY, 0)
        XCTAssertEqual(view.textView.frame.height, view.bounds.height)
    }
}

final class CaptionsTextDiffTests: XCTestCase {
    private func apply(_ edits: [CaptionsTextEdit], to old: String) -> String {
        let result = NSMutableString(string: old)
        for edit in edits.reversed() { result.replaceCharacters(in: edit.range, with: edit.replacement) }
        return result as String
    }

    func testSeparatedCorrectionsProduceSeparateEdits() {
        let old = "Этот малчик показывает как работает приложение и потом включает перевод"
        let new = "Этот мальчик показывает, как работает приложение и затем включает перевод."
        let edits = CaptionsTextDiff.edits(from: old, to: new)
        let unchanged = (old as NSString).range(of: "как работает приложение")
        XCTAssertGreaterThanOrEqual(edits.count, 3)
        for edit in edits { XCTAssertEqual(NSIntersectionRange(edit.range, unchanged).length, 0) }
        XCTAssertEqual(apply(edits, to: old), new)
    }

    func testAppendingPromotingClearingAndReplacingUnicode() {
        let examples: [(String, String)] = [
            ("", "Начало"), ("Начало", "Начало продолжение"), ("готово", "готово"), ("готово", ""),
            ("cafe\u{301} 👩🏽‍💻", "café 👨‍👩‍👧‍👦"), ("e", "e\u{301}"),
            ("你好吗世界", "你好，世界！"), ("one\nunchanged\nthree", "One\nunchanged\nThree"),
            (String(repeating: "а", count: 5000), String(repeating: "б", count: 5000)),
        ]
        for (old, new) in examples {
            let edits = CaptionsTextDiff.edits(from: old, to: new)
            XCTAssertEqual(Array(apply(edits, to: old).utf16), Array(new.utf16))
        }
        XCTAssertTrue(CaptionsTextDiff.edits(from: "готово", to: "готово").isEmpty)
    }

    func testMixedEditsReconstructTheExactAuthoritativeText() {
        // Pinned pseudo-random stream includes repeats, punctuation and multi-unit
        // graphemes; catches offset drift when several insertions/deletions mix.
        var seed: UInt64 = 42
        func next(_ upper: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(upper))
        }
        let alphabet = ["а", "б", " ", ",", "👩🏽‍💻", "e\u{301}", "é", "你", "\n"]
        for _ in 0..<200 {
            let old = (0..<30).map { _ in alphabet[next(alphabet.count)] }
            var new = old
            for _ in 0..<6 {
                let index = next(new.count)
                switch next(3) {
                case 0: new.remove(at: index)
                case 1: new.insert(alphabet[next(alphabet.count)], at: index)
                default: new[index] = alphabet[next(alphabet.count)]
                }
            }
            let a = old.joined(), b = new.joined()
            XCTAssertEqual(Array(apply(CaptionsTextDiff.edits(from: a, to: b), to: a).utf16), Array(b.utf16))
        }
    }
}

@MainActor
final class CaptionsCustomizationTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "CaptionsCustomizationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAppearanceAndPerScreenFramesSurviveReload() {
        let preferences = CaptionsPreferences(defaults: defaults)
        preferences.appearance.fontFamily = "Menlo"
        preferences.appearance.automaticFontSize = false
        preferences.appearance.fontSize = 34
        preferences.appearance.backgroundOpacity = 0.45
        preferences.appearance.textColor = CaptionsColor(.cyan)
        preferences.appearance.translationColor = CaptionsColor(.green)
        preferences.appearance.backgroundColor = CaptionsColor(.blue)
        let visible = NSRect(x: -1920, y: 24, width: 1920, height: 1056)
        let first = NSRect(x: -1500, y: 120, width: 900, height: 350)
        let second = NSRect(x: -1100, y: 240, width: 700, height: 250)
        preferences.save(frame: first, on: "first", visible: visible)
        preferences.save(frame: second, on: "second", visible: visible)
        let loaded = CaptionsPreferences(defaults: defaults)
        XCTAssertEqual(loaded.appearance, preferences.appearance)
        XCTAssertEqual(loaded.placement(for: "first")?.frame(in: visible), first)
        XCTAssertEqual(loaded.placement(for: "second")?.frame(in: visible), second)
        loaded.resetPlacement(for: "first")
        XCTAssertNil(CaptionsPreferences(defaults: defaults).placement(for: "first"))
        XCTAssertNotNil(CaptionsPreferences(defaults: defaults).placement(for: "second"))
    }

    func testPreviewUnlocksWithoutRecordingAndDoneDismissesIt() {
        let overlay = CaptionsOverlay(defaults: defaults)
        overlay.setEditing(true, display: CaptionsDisplay.followCursor, translating: true)
        XCTAssertTrue(overlay.isVisible)
        XCTAssertTrue(overlay.acceptsInteraction)
        XCTAssertEqual(overlay.model.layout.translationLines, 3)
        overlay.setEditing(false)
        XCTAssertFalse(overlay.acceptsInteraction)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertFalse(overlay.isVisible)
    }

    func testLockingLiveCaptionsKeepsTextAndWindowVisible() {
        let overlay = CaptionsOverlay(defaults: defaults)
        overlay.begin(target: "EN", display: CaptionsDisplay.followCursor)
        overlay.update(confirmed: "Продолжаем выступление", partial: "новая фраза")
        overlay.setEditing(true)
        overlay.setEditing(false)
        XCTAssertTrue(overlay.isVisible)
        XCTAssertFalse(overlay.acceptsInteraction)
        XCTAssertEqual(overlay.model.confirmed, "Продолжаем выступление")
        XCTAssertEqual(overlay.model.partial, "новая фраза")
        overlay.dismiss()
    }

    func testResizeAddsLinesAndRestoresPositionAtNextStart() throws {
        let screen = try XCTUnwrap(CaptionsDisplay.resolve(CaptionsDisplay.followCursor))
        let overlay = CaptionsOverlay(defaults: defaults)
        overlay.begin(target: "EN", display: CaptionsDisplay.followCursor)
        let original = try XCTUnwrap(overlay.panelFrame)
        overlay.setEditing(true)
        let larger = NSRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 25,
                            width: original.width * 0.8, height: original.height * 1.6)
        overlay.setManualFrame(larger)
        let saved = try XCTUnwrap(overlay.panelFrame)
        XCTAssertGreaterThan(overlay.model.layout.transcriptLines, 3)
        XCTAssertGreaterThan(overlay.model.layout.translationLines, 3)
        XCTAssertEqual(saved.size, overlay.model.layout.bandSize)
        overlay.dismiss()
        let restored = CaptionsOverlay(defaults: defaults)
        restored.begin(target: "EN", display: CaptionsDisplay.followCursor)
        XCTAssertEqual(try XCTUnwrap(restored.panelFrame).minX, saved.minX, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(restored.panelFrame).height, saved.height, accuracy: 0.5)
        restored.preferences.appearance.automaticFontSize = false
        restored.preferences.appearance.fontSize = 38
        XCTAssertEqual(restored.model.layout.fontSize, 38)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(restored.panelFrame).height, restored.model.layout.minimumSize.height)
        restored.resetPlacement(display: CaptionsDisplay.followCursor)
        XCTAssertEqual(restored.model.layout.transcriptLines, 3)
        restored.dismiss()
    }

    func testFrameFittingAndCornerDragKeepThePanelReachable() {
        let visible = NSRect(x: -1600, y: 40, width: 1600, height: 860)
        let fitted = CaptionsPlacement.fitted(NSRect(x: -3000, y: -100, width: 2400, height: 1200),
                                              visible: visible, minimum: CGSize(width: 320, height: 200))
        XCTAssertEqual(fitted, visible)
        let original = NSRect(x: 100, y: 100, width: 800, height: 300)
        let resized = CaptionsInteractionView.dragged(frame: original, dx: 120, dy: -80, resizing: true,
                                                       minimum: CGSize(width: 320, height: 200))
        XCTAssertEqual(resized.maxY, original.maxY)
        XCTAssertEqual(resized.minX, original.minX)
        XCTAssertEqual(resized.size, CGSize(width: 920, height: 380))
        let moved = CaptionsInteractionView.dragged(frame: original, dx: -30, dy: 40, resizing: false, minimum: .zero)
        XCTAssertEqual(moved, original.offsetBy(dx: -30, dy: 40))
    }

    func testFontAndColorsUpdateAlreadyVisibleText() throws {
        let view = CaptionsTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 140))
        view.layoutSubtreeIfNeeded()
        view.update(confirmed: "Readable text", partial: "", size: 25, color: .white)
        view.update(confirmed: "Readable text", partial: "", size: 34, color: .cyan, family: "Menlo")
        let storage = try XCTUnwrap(view.textView.textStorage)
        let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.familyName, "Menlo")
        XCTAssertEqual(font.pointSize, 34)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .cyan)
    }
}
