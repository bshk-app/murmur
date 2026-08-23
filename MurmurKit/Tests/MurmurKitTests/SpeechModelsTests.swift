import XCTest
@testable import MurmurKit

/// The app runs dictation and captions from one set of weights. Nemotron plus
/// Parakeet is ~3.4 GB, and each `TwoTierEngine` also sets its own Metal memory
/// cap, so a second copy is not a tuning regression — it is the difference
/// between the app working and the machine swapping.
final class SpeechModelsTests: XCTestCase {
    /// Both pipelines built from one `SpeechModels` drive the same engine, so
    /// whichever mode loads first warms the other.
    func test_sessions_from_one_models_object_share_the_engine() {
        let models = SpeechModels()
        let dictation = DictationSession(models: models)
        let captions = CaptionSession(models: models)

        XCTAssertTrue(dictation.engine === captions.engine)
    }

    /// The convenience initialiser still gives a standalone stack — the CLI drives
    /// one pipeline per process and should not have to name a shared object.
    func test_default_initialisers_are_independent() {
        XCTAssertFalse(DictationSession().engine === CaptionSession().engine)
    }

    /// Two `SpeechModels` are two stacks: sharing is explicit, never accidental.
    func test_separate_models_objects_do_not_share() {
        let dictation = DictationSession(models: SpeechModels())
        let captions = CaptionSession(models: SpeechModels())

        XCTAssertFalse(dictation.engine === captions.engine)
    }
}
