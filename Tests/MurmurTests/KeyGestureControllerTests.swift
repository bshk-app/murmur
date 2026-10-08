import XCTest
@testable import Murmur
@testable import MurmurKit

/// Records what the controller asks the key tap to hold back.
private final class CaptureRecorder: KeyCaptureSink {
    private(set) var history: [KeyCapture] = []
    /// Stands in for a Return the tap held back while finishing.
    var heldBackReturn = false
    var current: KeyCapture? { history.last }
    func setCapture(_ capture: KeyCapture) {
        history.append(capture)
        if capture != .finishing { heldBackReturn = false }
    }
    func endCapture() -> Bool {
        history.append(.off)
        defer { heldBackReturn = false }
        return heldBackReturn
    }
}

/// "Tap right ⌘, talk, press Return": what each gesture does to a session, and
/// what the key tap is told to hold back at every step. The capture matters
/// as much as the gesture: left on after a dictation, it would swallow Return
/// in every app on the Mac.
@MainActor
final class KeyGestureControllerTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private let keys = [AppMode.defaultsKey, TriggerMode.defaultsKey, RightCommandTrigger.key,
                        DictationEnabled.key]

    override func setUpWithError() throws {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(AppMode.dictation.rawValue, forKey: AppMode.defaultsKey)
        // Hold is the default and the case where a tap-started session differs
        // from a shortcut-started one.
        UserDefaults.standard.set(TriggerMode.hold.rawValue, forKey: TriggerMode.defaultsKey)
        UserDefaults.standard.removeObject(forKey: RightCommandTrigger.key)
        UserDefaults.standard.removeObject(forKey: DictationEnabled.key)
    }

    override func tearDownWithError() throws {
        for key in keys {
            if let value = saved[key], let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private var returnsPressed = 0

    private func controller() -> (DictationController, FakeDictationSession, CaptureRecorder) {
        let controller = DictationController()
        let fake = FakeDictationSession()
        let recorder = CaptureRecorder()
        controller.session = fake
        controller.keyCaptureSink = recorder
        returnsPressed = 0
        controller.pressReturn = { [unowned self] in self.returnsPressed += 1 }
        return (controller, fake, recorder)
    }

    /// A tap-on dictation, finished with Return, its paste just posted.
    private func pasted(_ controller: DictationController, alreadySubmitting: Bool = false) async {
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        controller.handle(.confirm)
        await controller.recordingTask?.value
        controller.holdReturnUntilPasteLands(alreadySubmitting: alreadySubmitting)
    }

    func testARightCommandTapStartsATapOnSessionThatReturnFinishes() async {
        let (controller, fake, recorder) = controller()

        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertEqual(controller.state, .recording)
        XCTAssertTrue(controller.latchedToggle, "a tap leaves no key to release")
        XCTAssertTrue(controller.confirmsWithReturn)
        XCTAssertEqual(recorder.current, .recording)

        controller.handle(.confirm)
        XCTAssertEqual(controller.state, .transcribing)
        XCTAssertEqual(recorder.current, .finishing)

        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(fake.finishCount, 1)
        XCTAssertEqual(controller.state, .transcribed(""))
        XCTAssertEqual(recorder.current, .off, "Return must be the apps' again once the text is in")
    }

    func testASecondTapStopsTooWithoutReturn() async {
        let (controller, fake, recorder) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value

        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(recorder.current, .off)
    }

    /// Escape stops the microphone the ordinary way - the session's
    /// lifecycle must still close - and inserts nothing.
    func testEscapeThrowsTheDictationAway() async {
        let (controller, fake, recorder) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value

        controller.handle(.cancel)
        XCTAssertEqual(recorder.current, .off,
                       "nothing is coming, so a Return now is the user's and must reach the app")
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(fake.finishCount, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.submitRequested)
    }

    /// The race this exists for: Return, then Return again to send, before
    /// the final text is ready. The second one would otherwise reach the chat
    /// first and send it without the dictation in it.
    func testReturnWhileFinishingSendsAfterThePaste() async {
        let (controller, _, _) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value

        controller.handle(.confirm)
        controller.handle(.submitWhenDone)
        XCTAssertTrue(controller.submitRequested)
        await controller.recordingTask?.value
    }

    /// The first Return lands while the microphone is still opening, so the
    /// stop is deferred; the second must still mean "and send it".
    func testReturnTwiceDuringStartStillSends() async {
        let (controller, fake, _) = controller()
        var release: CheckedContinuation<Void, Never>?
        fake.startGate = { await withCheckedContinuation { release = $0 } }
        controller.handle(.rightCommandTap)
        while release == nil { await Task.yield() }

        controller.handle(.confirm)
        controller.handle(.submitWhenDone)
        XCTAssertTrue(controller.submitRequested)
        release?.resume()
        await controller.recordingTask?.value
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
    }

    /// Waits out the paste-settle window on the main run loop.
    private func settle() async {
        try? await Task.sleep(for: .seconds(TextInjector.pasteSettleDelay + 0.15))
    }

    /// After the paste is posted the chat may not have applied it yet; a
    /// Return let through then would send the field without the text. It
    /// stays held back for the window, then goes back to the app.
    func testReturnStaysCapturedWhileThePasteLands() async {
        let (controller, _, recorder) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        controller.handle(.confirm)
        await controller.recordingTask?.value

        controller.holdReturnUntilPasteLands(alreadySubmitting: false)
        XCTAssertEqual(controller.keyCapture, .finishing)
        XCTAssertEqual(recorder.current, .finishing)

        await settle()
        XCTAssertFalse(controller.pasteSettling)
        XCTAssertEqual(controller.keyCapture, .off)
        XCTAssertEqual(recorder.current, .off)
    }

    /// Tapping straight into the next dictation: the old paste's window
    /// closing must not release Return from under the new recording.
    func testTheNextRecordingKeepsItsCaptureWhenTheOldPasteSettles() async {
        let (controller, _, recorder) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        controller.handle(.confirm)
        await controller.recordingTask?.value
        controller.holdReturnUntilPasteLands(alreadySubmitting: false)

        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(recorder.current, .recording)

        await settle()
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(recorder.current, .recording, "the old window closed over the new session")
    }

    /// Return pressed while the paste lands: sent once the window closes.
    func testAReturnHeldBackWhileThePasteLandsIsSentAfterIt() async {
        let (controller, _, recorder) = controller()
        await pasted(controller)
        recorder.heldBackReturn = true
        XCTAssertEqual(returnsPressed, 0, "not before the paste has landed")
        await settle()
        XCTAssertEqual(returnsPressed, 1)
    }

    /// Dictate-and-send already ends with a Return; a second would send an
    /// empty message after it.
    func testNoSecondReturnWhenThePasteAlreadySends() async {
        let (controller, _, recorder) = controller()
        await pasted(controller, alreadySubmitting: true)
        recorder.heldBackReturn = true
        await settle()
        XCTAssertEqual(returnsPressed, 0)
    }

    /// Return to send A, then straight into dictation B: B's capture must not
    /// swallow A's send.
    func testTappingIntoTheNextDictationStillSendsThePreviousOne() async {
        let (controller, _, recorder) = controller()
        await pasted(controller)
        recorder.heldBackReturn = true

        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(returnsPressed, 0, "A's paste may not have landed yet")
        await settle()
        XCTAssertEqual(returnsPressed, 1)
        XCTAssertEqual(recorder.current, .recording)
    }

    /// A new dictation must not inherit the previous one's "and send it".
    func testASubmitRequestDoesNotOutliveItsSession() async {
        let (controller, _, _) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        controller.handle(.confirm)
        controller.handle(.submitWhenDone)
        await controller.recordingTask?.value

        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertFalse(controller.submitRequested)
    }

    /// Holding a chord already says when the dictation ends; Return and
    /// Escape stay with the app.
    func testAHoldSessionCapturesNothing() async {
        let (controller, _, recorder) = controller()
        controller.beginRecording(submit: false)
        await controller.recordingTask?.value
        XCTAssertEqual(controller.state, .recording)
        XCTAssertFalse(controller.confirmsWithReturn)
        XCTAssertEqual(recorder.current, .off)

        controller.handle(.confirm)
        controller.handle(.cancel)
        XCTAssertEqual(controller.state, .recording, "a Return that was never captured cannot stop it")

        // Nor does a tap take over a session someone is holding a chord for.
        controller.handle(.rightCommandTap)
        XCTAssertEqual(controller.state, .recording)
    }

    /// Every tap-on session finishes on Return, however it was started.
    func testToggleShortcutAndMenuSessionsFinishOnReturn() async {
        UserDefaults.standard.set(TriggerMode.toggle.rawValue, forKey: TriggerMode.defaultsKey)
        let (controller, _, recorder) = controller()
        controller.beginRecording(submit: false)
        await controller.recordingTask?.value
        XCTAssertEqual(recorder.current, .recording)
        controller.handle(.confirm)
        await controller.recordingTask?.value

        UserDefaults.standard.set(TriggerMode.hold.rawValue, forKey: TriggerMode.defaultsKey)
        controller.toggleFromMenu()
        await controller.recordingTask?.value
        XCTAssertEqual(recorder.current, .recording)
    }

    /// A talk runs for an hour while the speaker types notes.
    func testCaptionsCaptureNothing() async {
        UserDefaults.standard.set(AppMode.captions.rawValue, forKey: AppMode.defaultsKey)
        let (controller, fake, recorder) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertFalse(controller.confirmsWithReturn)
        XCTAssertEqual(recorder.current, .off)
    }

    func testTheTapCanBeSwitchedOff() async {
        UserDefaults.standard.set(false, forKey: RightCommandTrigger.key)
        let (controller, fake, _) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 0)
    }

    /// Same rule as the shortcut: the master switch blocks starting.
    func testTheMasterSwitchBlocksTheTap() async {
        UserDefaults.standard.set(false, forKey: DictationEnabled.key)
        let (controller, fake, _) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 0)
    }

    /// A failed start must release Return, or a broken microphone would also
    /// break the Return key.
    func testAFailedStartReleasesTheCapture() async {
        let (controller, fake, recorder) = controller()
        fake.startError = NSError(domain: "test", code: 1)
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(recorder.current, .off)
    }

    /// Escape pressed while the microphone is still opening: the session
    /// starts, stops at once, and nothing is inserted.
    func testEscapeDuringStartStillDiscards() async {
        let (controller, fake, recorder) = controller()
        var release: CheckedContinuation<Void, Never>?
        fake.startGate = { await withCheckedContinuation { release = $0 } }
        controller.handle(.rightCommandTap)
        while release == nil { await Task.yield() }

        controller.handle(.cancel)
        release?.resume()
        await controller.recordingTask?.value
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(recorder.current, .off)
    }
}
