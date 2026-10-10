import XCTest
@testable import Murmur
@testable import MurmurKit

/// The Mac transcribes with Parakeet (and drafts with Nemotron). The language
/// menu once listed every translation language, so it offered Catalan, Arabic
/// and others neither model knows, and picking one gave text in the wrong
/// language.
@MainActor
final class MenuLanguagesTests: XCTestCase {
    func test_the_menu_offers_only_languages_the_mac_can_recognize() {
        let codes = DictationController().supportedLanguageCodes
        XCTAssertEqual(codes.first, SpeechLanguage.automatic)
        for code in SpeechModelChoice.whisperLanguages.union(["ar", "ga"]) {
            XCTAssertFalse(codes.contains(code), "\(code) is offered but the Mac cannot recognize it")
        }
        for code in ["en", "ru", "uk", "de", "fi"] {
            XCTAssertTrue(codes.contains(code), "\(code) is missing")
        }
    }
}
