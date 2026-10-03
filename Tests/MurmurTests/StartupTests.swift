import XCTest
@testable import Murmur
@testable import MurmurKit

/// Covers what `bootstrap` promises to do at launch.
///
/// These assert on the startup *declaration* rather than calling `bootstrap()`,
/// because that method registers global Carbon hotkeys, raises the microphone
/// permission prompt and loads multi-gigabyte models. Executing it in a unit
/// test would be slow, permission-dependent and destructive to the developer's
/// machine. The omission being guarded against is visible in the declaration,
/// so that is what gets checked.
final class StartupTests: XCTestCase {

    /// The regression: a translation target chosen in an earlier run whose
    /// download never finished would not resume, because the only trigger was
    /// the picker changing and relaunching does not change it. Dictation then
    /// silently produced untranslated text.
    func testStartupPreparesTranslationModels() {
        XCTAssertTrue(
            DictationController.startupSteps.contains(.translationModels),
            "launch no longer resumes translation model downloads; a target "
            + "chosen in a previous run would never finish downloading")
    }

    /// Catches the general form of the same bug for every future step: a case
    /// added to `StartupStep` but never added to the list that `bootstrap`
    /// walks. Without this, the next omission is found by a user, not here.
    func testEveryDeclaredStartupStepIsActuallyPerformed() {
        let performed = Set(DictationController.startupSteps)
        let declared = Set(DictationController.StartupStep.allCases)
        XCTAssertEqual(
            performed, declared,
            "declared but never performed: \(declared.subtracting(performed))")
    }

    /// A step run twice would prompt for the microphone twice or start the
    /// same download concurrently.
    func testNoStartupStepRunsTwice() {
        let steps = DictationController.startupSteps
        XCTAssertEqual(steps.count, Set(steps).count,
                       "a startup step is listed more than once")
    }

    /// Translation preparation needs the chosen mode's state settled first;
    /// ordering is part of the contract, not incidental.
    func testTranslationIsPreparedAfterTheModeIsReady() throws {
        let steps = DictationController.startupSteps
        let mode = try XCTUnwrap(steps.firstIndex(of: .currentMode))
        let translation = try XCTUnwrap(steps.firstIndex(of: .translationModels))
        XCTAssertLessThan(mode, translation)
    }
}
