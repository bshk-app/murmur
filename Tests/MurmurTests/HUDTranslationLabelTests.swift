import XCTest
@testable import Murmur

/// `translationIsQuality` is purely a display label - it decides whether the
/// HUD prints "Quality translation" under the second line - but a stale
/// `true` reads as a claim about the text on screen that is no longer true.
/// Two ways it could go stale: a fresh dictation utterance inheriting the
/// previous one's flag, and a caption session (which never uses the quality
/// engine at all) inheriting it from a dictation utterance that ran earlier
/// in the same launch.
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

    func testShowTranslationItselfClearsTheQualityLabel() {
        let hud = HUDController()
        hud.begin(lang: "RU")
        // Set directly, bypassing begin()'s own reset: begin() already proved
        // it clears the flag above, and calling it again here would let that
        // same reset pass this test even if showTranslation did nothing -
        // the point is to isolate showTranslation's own defensive reset.
        hud.model.translationIsQuality = true

        // Captions reuse the same HUDController; their rolling line goes
        // through showTranslation, not finish, and CaptionTranslator has no
        // quality path at all.
        hud.showTranslation("fast caption line")
        XCTAssertFalse(hud.model.translationIsQuality,
                       "captions never use the quality engine and must never claim to")
    }
}
