import XCTest
@testable import MurmurKit

final class LanguagePromptTests: XCTestCase {
    func test_supported_languages_collapse_prompt_aliases() {
        let prompts = [
            "en-US": 0, "en": 0,
            "en-GB": 1, "enGB": 1,
            "ru-RU": 11, "ru": 11,
            "auto": 101,
        ]

        XCTAssertEqual(
            TwoTierEngine.canonicalLanguageCodes(prompts),
            ["auto", "en", "en-GB", "ru"]
        )
    }
}
