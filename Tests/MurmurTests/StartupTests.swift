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

    /// A caption translation is a synchronous C++ call that `cancel()` cannot
    /// interrupt, so stopping a talk must invalidate the stamp its result is
    /// checked against. Without this, a pass still in the engine when the user
    /// stops comes back and writes the previous talk's translation under the
    /// next one's text.
    @MainActor
    func testStoppingCaptionsRetiresTranslationsAlreadyInFlight() {
        let controller = DictationController()
        let inFlight = controller.captionGeneration
        XCTAssertTrue(controller.captionTranslationIsCurrent(inFlight))

        controller.retireCaptionTranslations()

        XCTAssertFalse(controller.captionTranslationIsCurrent(inFlight),
                       "a translation from the finished talk would still be shown")
    }

    /// Each stop must retire again, or a second late result slips through.
    @MainActor
    func testEveryRetireInvalidatesAnew() {
        let controller = DictationController()
        let first = controller.captionGeneration
        controller.retireCaptionTranslations()
        let second = controller.captionGeneration
        controller.retireCaptionTranslations()

        XCTAssertFalse(controller.captionTranslationIsCurrent(first))
        XCTAssertFalse(controller.captionTranslationIsCurrent(second))
        XCTAssertTrue(controller.captionTranslationIsCurrent(controller.captionGeneration))
    }

    /// The bug a live screenshot caught: a phrase closes, its translation is
    /// missing from the HUD, and no further speech arrives to correct it.
    /// Snapshots arrive several times a second and each pass is coalesced by
    /// cancelling the previous one, but `cancel()` cannot interrupt a call
    /// already inside the synchronous, non-cancellable C++ engine - so an
    /// older snapshot's pass can finish *after* a newer one's. Before this
    /// fix every snapshot in one talk shared the single generation stamped at
    /// session start, so that older, shorter result read as just as "current"
    /// as the newer, complete one and could silently overwrite it. Proven at
    /// the stamping level, not by racing real translation timing: each call
    /// must mint its own generation regardless of what the engine does with
    /// it afterward.
    @MainActor
    func testEachCaptionSnapshotGetsItsOwnGenerationEvenWithinOneTalk() async {
        let controller = DictationController()
        // Without this the call below loads real bergamot weights on the
        // cooperative pool - the app has a SIGSEGV on record from exactly
        // that path (`YAML::RegEx::MatchUnchecked` recursion) - and leaves the
        // work running past the end of the test. The generation stamping this
        // test is about is decided before any of that, so a fake costs the
        // test nothing.
        controller.captionTranslation = CaptionTranslator(service: InertTranslator())
        let savedTarget = UserDefaults.standard.string(forKey: TranslationSetting.key)
        defer {
            if let savedTarget {
                UserDefaults.standard.set(savedTarget, forKey: TranslationSetting.key)
            } else {
                UserDefaults.standard.removeObject(forKey: TranslationSetting.key)
            }
        }
        UserDefaults.standard.set("en", forKey: TranslationSetting.key)
        controller.captionSource = "ru"

        let first = CaptionSnapshot(revision: 1, confirmed: [], provisional: "Раз, два, три")
        controller.translateCaptions(first)
        let firstGeneration = controller.captionGeneration

        let second = CaptionSnapshot(
            revision: 2,
            confirmed: [CaptionSegment(id: 1, startSample: 0, endSample: 100,
                                        text: "Раз, два, три.", state: .confirmed)],
            provisional: "")
        controller.translateCaptions(second)
        let secondGeneration = controller.captionGeneration
        // Drained so no translation task outlives the test that started it.
        await controller.captionTranslateTask?.value

        XCTAssertNotEqual(firstGeneration, secondGeneration,
                          "two snapshots in the same talk must not share a stamp")
        XCTAssertFalse(controller.captionTranslationIsCurrent(firstGeneration),
                       "the first snapshot's pass must be rejected once a newer one has "
                       + "started, even if it happens to finish later")
        XCTAssertTrue(controller.captionTranslationIsCurrent(secondGeneration))
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
