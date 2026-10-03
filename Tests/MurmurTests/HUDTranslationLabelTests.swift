import XCTest
@testable import Murmur

/// `translationIsQuality` is purely a display label - it decides whether the
/// HUD prints "Quality translation" under the second line - but a stale
/// `true` reads as a claim about the text on screen that is no longer true.
/// The way it could go stale: a fresh dictation utterance inheriting the
/// previous one's flag.
@MainActor
final class HUDTranslationLabelTests: XCTestCase {
    func testANewUtteranceDoesNotInheritThePreviousOnesQualityLabel() {
        let hud = HUDController()
        hud.begin(lang: "RU")
        hud.finish("final text", delivery: .typed, translation: "quality result",
                  translationIsQuality: true)
        XCTAssertTrue(hud.model.translationIsQuality)

        hud.begin(lang: "RU")   // next utterance's HUD session
        XCTAssertFalse(hud.model.translationIsQuality,
                       "a fresh session must not still claim the old translation was quality")
    }
}
