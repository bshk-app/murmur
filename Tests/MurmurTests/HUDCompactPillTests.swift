import XCTest
import MurmurKit
@testable import Murmur

/// The compact pill exists so that nothing on screen grows, moves or rewrites
/// itself while you speak. These pin the two ways it could stop doing that:
/// the window changing size mid-utterance, and the compact pill hiding text
/// the user still has to read.
@MainActor
final class HUDCompactPillTests: XCTestCase {
    private var saved: String?

    override func setUp() {
        saved = UserDefaults.standard.string(forKey: HUDStyle.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: HUDStyle.defaultsKey)
    }

    func testTheCaretIsTheDefault() {
        UserDefaults.standard.removeObject(forKey: HUDStyle.defaultsKey)
        XCTAssertEqual(HUDStyle.current, .caret)
        UserDefaults.standard.set(HUDStyle.full.rawValue, forKey: HUDStyle.defaultsKey)
        XCTAssertEqual(HUDStyle.current, .full)
    }

    func testTheWindowKeepsItsSizeWhileYouSpeakAndWhileItFinishes() throws {
        let hud = HUDController()
        hud.begin(lang: "RU", interactive: true, confirmsWithReturn: true, style: .compact)
        let atStart = try XCTUnwrap(hud.panelSize)
        let width = hud.model.compactWidth
        XCTAssertTrue(hud.model.showsCompactPill)

        hud.update(confirmed: "a long first sentence that would grow the full pill", partial: "and more")
        XCTAssertEqual(hud.panelSize, atStart)
        hud.finalizing()
        XCTAssertEqual(hud.panelSize, atStart)
        hud.willSubmit()
        XCTAssertEqual(hud.panelSize, atStart)
        hud.translating()
        XCTAssertEqual(hud.panelSize, atStart, "there is no translation row to make room for")
        XCTAssertEqual(hud.model.compactWidth, width)
    }

    /// Fixed per utterance, but not one size for all: bars alone for
    /// hold-to-talk, room for ⏎ and Stop when the take can show them - and
    /// never wider than the window it sits in.
    func testTheCapsuleIsAsWideAsWhatThisUtteranceCanShow() {
        let hud = HUDController()
        hud.begin(lang: "RU", style: .compact)
        let hold = hud.model.compactWidth
        hud.begin(lang: "RU", submits: true, style: .compact)
        let holdAndSend = hud.model.compactWidth
        hud.begin(lang: "RU", interactive: true, confirmsWithReturn: true, style: .compact)
        let tap = hud.model.compactWidth
        XCTAssertLessThan(hold, holdAndSend)
        XCTAssertLessThan(holdAndSend, tap)
        XCTAssertLessThanOrEqual(tap, HUDController.compactPillSize.width)
    }

    /// In toggle mode the window takes clicks, so its size is the area of
    /// screen the HUD blocks. A small pill must not block a full-pill's worth.
    func testTheCompactWindowIsMuchSmallerThanTheFullOne() throws {
        let full = HUDController(), compact = HUDController()
        full.begin(lang: "RU", interactive: true, style: .full)
        compact.begin(lang: "RU", interactive: true, style: .compact)
        let f = try XCTUnwrap(full.panelSize), c = try XCTUnwrap(compact.panelSize)
        XCTAssertLessThan(c.width * c.height * 4, f.width * f.height)
        XCTAssertGreaterThanOrEqual(c.width, HUDController.compactPillSize.width + 2 * HUDController.sideInset)
    }

    /// Text that could not be typed lives only in the pill; the compact one
    /// has nowhere to put it, so the full pill takes over and the window grows.
    func testUndeliveredTextSwitchesToTheFullPill() throws {
        let hud = HUDController()
        hud.begin(lang: "RU", style: .compact)
        let compactSize = try XCTUnwrap(hud.panelSize)
        hud.finish("the words", delivery: .failed("Field is protected — press ⌘V"))
        XCTAssertFalse(hud.model.showsCompactPill)
        XCTAssertGreaterThan(hud.panelSize?.height ?? 0, compactSize.height)
    }

    func testAnErrorIsShownInFull() {
        let hud = HUDController()
        hud.begin(lang: "RU", style: .compact)
        hud.error("No microphone")
        XCTAssertFalse(hud.model.showsCompactPill)
    }

    func testTheStyleIsReadForEachUtterance() {
        let hud = HUDController()
        hud.begin(lang: "RU", style: .full)
        XCTAssertFalse(hud.model.showsCompactPill)
        hud.begin(lang: "RU", style: .compact)
        XCTAssertTrue(hud.model.showsCompactPill)
    }
}
