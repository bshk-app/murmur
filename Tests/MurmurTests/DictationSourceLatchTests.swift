import XCTest
@testable import Murmur
@testable import MurmurKit

/// The recogniser is handed a language when an utterance starts; the text it
/// returns is already a product of that choice. Translation used to re-read
/// the Language picker at stop instead, which is reachable mid-utterance in
/// toggle mode - the HUD stays up and the menu still opens. Switching it then
/// sent Russian speech to a German -> X model: a confidently wrong paste, with
/// no error anywhere to show it happened.
///
/// The target is deliberately *not* latched. It is a choice about the output,
/// so honouring the newest one is correct; the source is a fact about input
/// that has already been consumed. These prove the two are treated
/// differently, which is the whole distinction the bug missed.
///
/// These cover one half - that a latched value beats the live setting. That
/// `beginRecording` performs the latch at all is covered by
/// `BeginRecordingLatchTests`, which substitutes the session; it used to be
/// unreachable and is the reason `DictationSessioning` exists.
/// The Language picker being `.disabled(dictation.isActive)` is a second line
/// of defence - it makes the mid-utterance change unreachable rather than
/// merely harmless.
@MainActor
final class DictationSourceLatchTests: XCTestCase {
    private var savedLanguage: String?

    override func setUpWithError() throws {
        savedLanguage = UserDefaults.standard.string(forKey: SpeechLanguage.defaultsKey)
    }

    override func tearDownWithError() throws {
        if let savedLanguage {
            UserDefaults.standard.set(savedLanguage, forKey: SpeechLanguage.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SpeechLanguage.defaultsKey)
        }
    }

    private func language(_ code: String) {
        UserDefaults.standard.set(code, forKey: SpeechLanguage.defaultsKey)
    }

    func testChangingLanguageMidUtteranceDoesNotChangeWhatTheTranscriptRoutesFrom() {
        let controller = DictationController()
        language("ru")
        // The recogniser was started with Russian, as `beginRecording` latches it.
        controller.dictationSource = "ru"

        // The user opens the menu mid-utterance and switches to German.
        language("de")

        XCTAssertEqual(controller.translationSource, "ru",
                       "the text was recognised as Russian; routing it from German would "
                       + "produce a confidently wrong translation")
    }

    /// Without a session behind it there is no recognised text to be wrong
    /// about, so the live setting is the only answer available.
    func testWithoutALatchTheCurrentSettingIsUsed() {
        let controller = DictationController()
        language("de")
        XCTAssertNil(controller.dictationSource)
        XCTAssertEqual(controller.translationSource, "de")
    }

    /// A new utterance must pick up a language changed between utterances -
    /// the latch pins one session, it does not freeze the setting forever.
    func testANewUtteranceAdoptsALanguageChangedBetweenUtterances() {
        let controller = DictationController()
        controller.dictationSource = "ru"
        language("de")
        // What `beginRecording` does at the top of the next utterance.
        controller.dictationSource = SpeechLanguage.current

        XCTAssertEqual(controller.translationSource, "de")
    }
}
