import XCTest
import MurmurKit
@testable import Murmur

/// The design's translate HUD heads the pill with `RU → EN` rather than `RU`
/// alone (MurMur.dc.html, "Live translation · final corrector"), and that
/// arrow is what makes the quieter second line read as a translation instead
/// of a stray grey paragraph. The badge must therefore promise a target
/// exactly when one will actually arrive - a `→ EN` over an utterance that
/// ends up pasting the untranslated original is worse than no badge at all.
@MainActor
final class HUDLanguageBadgeTests: XCTestCase {
    private var savedLanguage: String?
    private var savedTarget: String?

    override func setUpWithError() throws {
        savedLanguage = UserDefaults.standard.string(forKey: SpeechLanguage.defaultsKey)
        savedTarget = UserDefaults.standard.string(forKey: TranslationSetting.key)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.set(savedLanguage, forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set(savedTarget, forKey: TranslationSetting.key)
    }

    private func set(target: String) {
        UserDefaults.standard.set(target, forKey: TranslationSetting.key)
    }

    func testARoutablePairYieldsTheTargetTag() {
        set(target: "en")
        XCTAssertEqual(TranslationSetting.badge(dictating: "ru"), "EN")
    }

    func testTranslationOffYieldsNoTag() {
        set(target: TranslationSetting.off)
        XCTAssertEqual(TranslationSetting.badge(dictating: "ru"), "",
                       "with the mode off there is no second line to explain")
    }

    /// Automatic detection cannot be translated - neither recogniser reports
    /// the language it heard - so there is no source to route from.
    func testAutomaticDetectionYieldsNoTag() {
        set(target: "en")
        XCTAssertEqual(TranslationSetting.badge(dictating: SpeechLanguage.automatic), "")
    }

    /// The badge is gated on the route resolving, not merely on a target
    /// being set: an unroutable pairing pastes the original transcript, and a
    /// badge is a promise the HUD would then break.
    func testAnUnroutablePairYieldsNoTagEvenThoughATargetIsSet() {
        set(target: "en")
        XCTAssertNotNil(TranslationSetting.target, "target is set; the gate must be the route")
        XCTAssertNil(LanguagePair.route(from: "xx", to: "en"),
                     "xx is expected to be unsupported; test assumption is stale")
        XCTAssertEqual(TranslationSetting.badge(dictating: "xx"), "")
    }

    func testBeginPutsTheTargetOnTheModelSoTheHeaderCanShowIt() {
        let hud = HUDController()
        hud.begin(lang: "RU", target: "EN")
        XCTAssertEqual(hud.model.lang, "RU")
        XCTAssertEqual(hud.model.target, "EN")
    }

    /// A target left over from a translated utterance would head the next,
    /// untranslated one with an arrow to nowhere.
    func testANewUntranslatedUtteranceClearsThePreviousTarget() {
        let hud = HUDController()
        hud.begin(lang: "RU", target: "EN")
        hud.begin(lang: "RU")
        XCTAssertEqual(hud.model.target, "")
    }
}
