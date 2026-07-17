import XCTest
@testable import Murmur

@MainActor
final class HUDControllerTests: XCTestCase {
    func testBeginResetsModelAndConfiguresInteractivePanel() {
        let (controller, _, animator) = makeHUDController()
        defer { tearDownHUD(controller) }

        controller.error("old error")
        controller.update(confirmed: "old", partial: "text")
        var stopped = false
        controller.begin(presentation: true, lang: "fr", interactive: true) { stopped = true }

        XCTAssertEqual(controller.model.phase, .listening)
        XCTAssertEqual(controller.model.confirmed, "")
        XCTAssertEqual(controller.model.partial, "")
        XCTAssertEqual(controller.model.lang, "fr")
        XCTAssertTrue(controller.model.presentation)
        XCTAssertTrue(controller.model.recording)
        XCTAssertTrue(controller.model.showStop)
        XCTAssertFalse(controller.panel?.ignoresMouseEvents ?? true)
        XCTAssertEqual(animator.shownPanels.count, 2)
        controller.model.onStop()
        XCTAssertTrue(stopped)
    }

    func testNonInteractiveBeginIgnoresMouseEvents() {
        let (controller, _, _) = makeHUDController()
        defer { tearDownHUD(controller) }

        controller.begin(presentation: false, lang: "Auto")

        XCTAssertTrue(controller.panel?.ignoresMouseEvents ?? false)
        XCTAssertFalse(controller.model.showStop)
    }

    func testUpdateTransitionsBetweenListeningAndTranscribing() {
        let (controller, _, _) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "Auto")

        controller.update(confirmed: "hello", partial: "wor")
        XCTAssertEqual(controller.model.phase, .transcribing)
        XCTAssertEqual(controller.model.confirmed, "hello")
        XCTAssertEqual(controller.model.partial, "wor")

        controller.update(confirmed: "", partial: "")
        XCTAssertEqual(controller.model.phase, .listening)
    }

    func testUpdateDoesNotReplaceErrorPhase() {
        let (controller, _, _) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.error("denied")

        controller.update(confirmed: "ignored", partial: "update")

        XCTAssertEqual(controller.model.phase, .error)
        XCTAssertEqual(controller.model.confirmed, "ignored")
        XCTAssertEqual(controller.model.partial, "update")
    }

    func testFinishSchedulesNormalAndPresentationDelays() {
        let (normal, normalScheduler, _) = makeHUDController()
        defer { tearDownHUD(normal) }
        normal.begin(presentation: false, lang: "Auto", interactive: true)
        normal.finish("final words")

        XCTAssertEqual(normalScheduler.entries.last?.delay, 1.0)
        XCTAssertEqual(normal.model.confirmed, "final words")
        XCTAssertEqual(normal.model.partial, "")
        XCTAssertEqual(normal.model.phase, .transcribing)
        XCTAssertFalse(normal.model.recording)
        XCTAssertFalse(normal.model.showStop)

        let (presentation, presentationScheduler, _) = makeHUDController()
        defer { tearDownHUD(presentation) }
        presentation.begin(presentation: true, lang: "Auto")
        presentation.finish("")
        XCTAssertEqual(presentationScheduler.entries.last?.delay, 4.0)
        XCTAssertEqual(presentation.model.phase, .listening)
    }

    func testFinishWithoutPanelIsIgnored() {
        let (controller, scheduler, _) = makeHUDController()

        controller.finish("orphan")

        XCTAssertTrue(scheduler.entries.isEmpty)
        XCTAssertEqual(controller.model.confirmed, "")
    }

    func testRepeatedFinishCancelsEarlierDeadline() {
        let (controller, scheduler, _) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "Auto")

        controller.finish("first")
        controller.finish("second")

        XCTAssertEqual(scheduler.entries.count, 2)
        XCTAssertTrue(scheduler.entries[0].cancellation.isCancelled)
        XCTAssertFalse(scheduler.entries[1].cancellation.isCancelled)
        scheduler.fire(0)
        XCTAssertNotNil(controller.panel)
    }

    func testErrorSchedulesHideAndPreservesDefaultForEmptyMessage() {
        let (controller, scheduler, _) = makeHUDController()
        defer { tearDownHUD(controller) }

        controller.error("")

        XCTAssertEqual(controller.model.phase, .error)
        XCTAssertEqual(controller.model.errorText, "Open Privacy in Settings →")
        XCTAssertFalse(controller.model.recording)
        XCTAssertEqual(scheduler.entries.last?.delay, 3.2)
    }

    func testBeginCancelsPendingHideAndInvalidatesItsAction() {
        let (controller, scheduler, animator) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.error("denied")
        let oldID = controller.presentationID

        controller.begin(presentation: false, lang: "en")

        XCTAssertTrue(scheduler.entries[0].cancellation.isCancelled)
        XCTAssertGreaterThan(controller.presentationID, oldID)
        scheduler.fire(0, evenIfCancelled: true)
        XCTAssertTrue(animator.hiddenPanels.isEmpty)
        XCTAssertNotNil(controller.panel?.contentView)
    }

    func testErrorCancelsPendingFinishAndInvalidatesItsAction() {
        let (controller, scheduler, animator) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "Auto")
        controller.finish("done")

        controller.error("denied")

        XCTAssertTrue(scheduler.entries[0].cancellation.isCancelled)
        XCTAssertEqual(scheduler.entries[1].delay, 3.2)
        scheduler.fire(0, evenIfCancelled: true)
        XCTAssertTrue(animator.hiddenPanels.isEmpty)
        XCTAssertEqual(controller.model.phase, .error)
    }

    func testStaleFadeCompletionCannotTearDownRePresentedHUD() {
        let (controller, scheduler, animator) = makeHUDController()
        defer { tearDownHUD(controller) }
        controller.begin(presentation: false, lang: "Auto")
        controller.finish("first")
        scheduler.fire(0)
        let originalPanel = controller.panel

        controller.begin(presentation: false, lang: "Auto")
        animator.completeHide()

        XCTAssertTrue(controller.panel === originalPanel)
        XCTAssertNotNil(controller.panel?.contentView)
        XCTAssertEqual(controller.model.phase, .listening)
    }
}
