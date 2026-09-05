import XCTest
import MurmurKit
@testable import Murmur

/// The quality-model control only offers what can actually succeed: a direct
/// pair (not a pivot - no pivot leg has a quality conversion yet) with a
/// published CTranslate2 model. These are the routing decisions behind that,
/// tested without touching the network.
@MainActor
final class DictationControllerQualityTests: XCTestCase {
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

    private func set(language: String, target: String) {
        UserDefaults.standard.set(language, forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set(target, forKey: TranslationSetting.key)
    }

    func testNoCandidateUnderAutomaticDetection() {
        set(language: SpeechLanguage.automatic, target: "en")
        let dictation = DictationController()
        XCTAssertNil(dictation.qualityCandidatePair,
                     "automatic detection has no source to route from")
    }

    func testNoCandidateWithTranslationOff() {
        set(language: "ru", target: TranslationSetting.off)
        let dictation = DictationController()
        XCTAssertNil(dictation.qualityCandidatePair)
    }

    func testDirectPairIsOfferedAsACandidate() {
        set(language: "ru", target: "en")
        let dictation = DictationController()
        XCTAssertEqual(dictation.qualityCandidatePair, LanguagePair(source: "ru", target: "en"))
    }

    /// fi -> de has no direct model (per LanguagePair.supportedLanguages'
    /// pivot table) and must route through English, so there is no single
    /// pair the button could act on.
    func testAPivotPairIsNotOfferedAsACandidate() {
        set(language: "fi", target: "de")
        let dictation = DictationController()
        guard case .pivot = LanguagePair.route(from: "fi", to: "de") else {
            return XCTFail("fi-de is expected to pivot; test assumption is stale")
        }
        XCTAssertNil(dictation.qualityCandidatePair,
                     "a pivot has no quality-converted leg yet; offering one would only fail")
    }

    /// Only ru-en and en-ru are actually converted. Every other direction,
    /// even a perfectly valid direct fast-tier pair, must not offer a button
    /// that can only end in `unpinnedDirection`.
    func testOnlyConvertedDirectionsAreOffered() {
        let dictation = DictationController()
        XCTAssertTrue(dictation.qualityModelIsOffered(
            for: LanguagePair(source: "ru", target: "en")))
        XCTAssertTrue(dictation.qualityModelIsOffered(
            for: LanguagePair(source: "en", target: "ru")))
        XCTAssertFalse(dictation.qualityModelIsOffered(
            for: LanguagePair(source: "de", target: "en")),
            "de-en has a fast model but no published quality conversion")
    }
}
