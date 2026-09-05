import XCTest
@testable import Murmur

/// A live screenshot showed the last line of a caption's translation clipped
/// at the bottom edge of the HUD panel: the panel is a fixed-size `NSPanel`
/// (`HUDController.baseSize`), sized to fit the transcript alone, and adding
/// a second, translated line without growing the window just lets SwiftUI's
/// content overflow the window's bounds. These prove the panel actually
/// grows when a translation row appears, and shrinks back when it does not
/// - not just that `HUDModel.showsTranslationRow` computes the right bool,
/// which alone would not have caught a codepath that computes the right
/// answer but forgets to apply it to the actual window.
@MainActor
final class HUDTranslationHeightTests: XCTestCase {
    func testThePanelGrowsWhenATranslationArrives() {
        let hud = HUDController()
        hud.begin(lang: "RU")
        let baseHeight = hud.panelSize?.height
        XCTAssertNotNil(baseHeight, "begin() must create the panel")

        hud.finish("hello", delivery: .typed, translation: "hola")

        XCTAssertGreaterThan(hud.panelSize?.height ?? 0, baseHeight ?? 0,
                             "a translation line arrived; the panel must have grown to fit it, "
                             + "not clipped it at the old height")
    }

    func testThePanelStaysAtBaseHeightWithoutATranslation() {
        let hud = HUDController()
        hud.begin(lang: "RU")
        let baseHeight = hud.panelSize?.height

        hud.finish("hello", delivery: .typed)   // no translation argument

        XCTAssertEqual(hud.panelSize?.height, baseHeight,
                       "plain dictation must keep the panel it always had")
    }

    /// The "Translating…" placeholder reserves the same room the final text
    /// will need, so the window does not resize twice in quick succession.
    func testThePanelGrowsForTheTranslatingPlaceholderToo() {
        let hud = HUDController()
        hud.begin(lang: "RU")
        let baseHeight = hud.panelSize?.height

        hud.translating()

        XCTAssertGreaterThan(hud.panelSize?.height ?? 0, baseHeight ?? 0,
                             "the placeholder line needs the same room the final text will")
    }

    /// A new utterance without a translation must shrink the panel back down
    /// - otherwise a translated utterance would leave every following plain
    /// one carrying dead space from a talk that has already ended.
    func testANewUtteranceWithoutTranslationShrinksThePanelBackDown() {
        let hud = HUDController()
        hud.begin(lang: "RU")
        hud.finish("hello", delivery: .typed, translation: "hola")
        let grownHeight = hud.panelSize?.height

        hud.begin(lang: "RU")

        XCTAssertLessThan(hud.panelSize?.height ?? 0, grownHeight ?? 0,
                          "a fresh utterance with no translation yet must not inherit the "
                          + "previous one's taller panel")
    }
}
