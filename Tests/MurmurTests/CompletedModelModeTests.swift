import XCTest
@testable import Murmur
@testable import MurmurKit

/// `dictation_started` and `dictation_completed` both carry `model_mode`, and
/// the pair is what makes the routing matrix measurable: which lane ran, and
/// what came out of it. Completion used to re-read `ModelSetting.current`,
/// which broke that pairing two different ways.
///
/// The second one is the reason this is worth a test rather than a shrug: it
/// needs nobody to touch anything, and it is silent.
///
/// These cover one half - that a latched value beats the live setting. That
/// `beginRecording` latches the *effective* mode rather than the raw setting
/// is covered by `BeginRecordingLatchTests`.
@MainActor
final class CompletedModelModeTests: XCTestCase {
    private var savedModel: String?

    override func setUpWithError() throws {
        savedModel = UserDefaults.standard.string(forKey: ModelSetting.key)
    }

    override func tearDownWithError() throws {
        if let savedModel {
            UserDefaults.standard.set(savedModel, forKey: ModelSetting.key)
        } else {
            UserDefaults.standard.removeObject(forKey: ModelSetting.key)
        }
    }

    private func setting(_ mode: DictationMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: ModelSetting.key)
    }

    /// Bug one: the user switches Model while the batch pass runs.
    func testSwitchingModelMidUtteranceDoesNotRelabelTheUtteranceThatAlreadyRan() {
        let controller = DictationController()
        setting(.hybrid)
        controller.dictationMode = .hybrid       // what beginRecording latched

        setting(.accurate)                       // user switches mid-utterance

        XCTAssertEqual(controller.completedModelMode, .hybrid,
                       "this utterance ran in Hybrid; reporting Accurate would attribute its "
                       + "output to a lane that never touched it")
    }

    /// Bug two, and the worse one: no user action at all. `beginRecording`
    /// starts the session with `effective(for:)`, which downgrades Hybrid to
    /// Accurate for languages with no live draft. Reading the raw setting at
    /// stop made every such utterance report started=accurate,
    /// completed=hybrid - a permanent disagreement between two events about
    /// the same utterance.
    func testADowngradedLanguageReportsTheLaneThatRanNotTheOneRequested() {
        let controller = DictationController()
        setting(.hybrid)
        let effective = ModelSetting.current.effective(for: "ja")
        XCTAssertEqual(effective, .accurate,
                       "ja is expected to have no live draft; test assumption is stale")

        // Exactly what beginRecording latches.
        controller.dictationMode = effective

        XCTAssertEqual(controller.completedModelMode, .accurate,
                       "Accurate is what actually ran, even though the picker still says Hybrid")
        XCTAssertNotEqual(controller.completedModelMode, ModelSetting.current,
                          "if these were equal the test would not be proving anything")
    }

    /// A language that keeps its live draft must not be downgraded - proving
    /// the fix reports the effective mode rather than just always saying
    /// Accurate.
    func testALanguageWithALiveDraftStillReportsHybrid() {
        let controller = DictationController()
        setting(.hybrid)
        controller.dictationMode = ModelSetting.current.effective(for: "ru")
        XCTAssertEqual(controller.completedModelMode, .hybrid)
    }

    /// Nothing ran, so the live setting is the only answer available.
    func testWithoutALatchTheCurrentSettingIsUsed() {
        let controller = DictationController()
        setting(.fast)
        XCTAssertNil(controller.dictationMode)
        XCTAssertEqual(controller.completedModelMode, .fast)
    }
}
