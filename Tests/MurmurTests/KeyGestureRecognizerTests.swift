import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import Murmur

/// The decisions behind "tap right ⌘, talk, press Return". The event tap that
/// feeds these cannot run in a test, so everything it decides is decided here.
final class KeyGestureRecognizerTests: XCTestCase {
    private var recognizer = KeyGestureRecognizer()

    private func feed(_ input: KeyInput, _ capture: KeyCapture = .off) -> KeyGestureRecognizer.Outcome {
        recognizer.handle(input, capture: capture)
    }

    private func rightCommand(down: Bool, at time: TimeInterval, also extra: KeyModifiers = []) -> KeyInput {
        .modifiersChanged(keyCode: kVK_RightCommand,
                          modifiers: down ? extra.union(.rightCommand) : extra,
                          time: time)
    }

    private func tap(at time: TimeInterval = 10, holding: TimeInterval = 0.1) -> [KeyGestureRecognizer.Outcome] {
        [feed(rightCommand(down: true, at: time)), feed(rightCommand(down: false, at: time + holding))]
    }

    // MARK: right ⌘

    func testALoneRightCommandTapIsTheTrigger() {
        let outcomes = tap()
        XCTAssertEqual(outcomes.map(\.gesture), [nil, .rightCommandTap])
        // The modifier itself always reaches the app: half a ⌘ press held back
        // could leave the app believing ⌘ is still down.
        XCTAssertEqual(outcomes.map(\.swallow), [false, false])
    }

    /// ⌘C typed with the right hand is a shortcut, not a dictation.
    func testRightCommandUsedForAShortcutIsNotATap() {
        _ = feed(rightCommand(down: true, at: 10))
        _ = feed(.keyDown(keyCode: kVK_ANSI_C, modifiers: .rightCommand, isRepeat: false))
        _ = feed(.keyUp(keyCode: kVK_ANSI_C))
        XCTAssertNil(feed(rightCommand(down: false, at: 10.2)).gesture)
    }

    func testRightCommandClickIsNotATap() {
        _ = feed(rightCommand(down: true, at: 10))
        _ = feed(.pointerDown)
        XCTAssertNil(feed(rightCommand(down: false, at: 10.2)).gesture)
    }

    /// ⌘⇧ chords, in either order.
    func testAnotherModifierMakesItAChord() {
        _ = feed(rightCommand(down: true, at: 10))
        _ = feed(.modifiersChanged(keyCode: kVK_Shift, modifiers: [.rightCommand, .shift], time: 10.05))
        _ = feed(.modifiersChanged(keyCode: kVK_Shift, modifiers: .rightCommand, time: 10.1))
        XCTAssertNil(feed(rightCommand(down: false, at: 10.15)).gesture)

        _ = feed(.modifiersChanged(keyCode: kVK_Shift, modifiers: .shift, time: 11))
        _ = feed(rightCommand(down: true, at: 11.05, also: .shift))
        _ = feed(.modifiersChanged(keyCode: kVK_Shift, modifiers: .rightCommand, time: 11.1))
        XCTAssertNil(feed(rightCommand(down: false, at: 11.15)).gesture)
    }

    /// Left ⌘ is everyone's shortcut key; only the right one is spare.
    func testLeftCommandIsNotTheTrigger() {
        _ = feed(.modifiersChanged(keyCode: kVK_Command, modifiers: .leftCommand, time: 10))
        XCTAssertNil(feed(.modifiersChanged(keyCode: kVK_Command, modifiers: [], time: 10.1)).gesture)

        // Both held, right released last: still a chord.
        _ = feed(.modifiersChanged(keyCode: kVK_Command, modifiers: .leftCommand, time: 11))
        _ = feed(rightCommand(down: true, at: 11.05, also: .leftCommand))
        _ = feed(.modifiersChanged(keyCode: kVK_Command, modifiers: .rightCommand, time: 11.1))
        XCTAssertNil(feed(rightCommand(down: false, at: 11.15)).gesture)
    }

    /// Resting a thumb on the key and changing your mind must not open the
    /// microphone.
    func testALongPressIsNotATap() {
        XCTAssertNil(tap(holding: KeyGestureRecognizer.maxTapDuration + 0.05).last?.gesture)
        XCTAssertEqual(tap(at: 20, holding: KeyGestureRecognizer.maxTapDuration - 0.05).last?.gesture,
                       .rightCommandTap)
    }

    /// One chord must not poison the next tap.
    func testATapAfterAChordStillCounts() {
        _ = feed(rightCommand(down: true, at: 10))
        _ = feed(.keyDown(keyCode: kVK_Tab, modifiers: .rightCommand, isRepeat: false))
        _ = feed(rightCommand(down: false, at: 10.2))
        XCTAssertEqual(tap(at: 11).last?.gesture, .rightCommandTap)
    }

    /// Synthetic events can carry ⌘ without a side; they must never pass for
    /// the trigger.
    func testSidelessCommandFlagReadsAsLeft() {
        let modifiers = KeyModifiers(.maskCommand)
        XCTAssertTrue(modifiers.contains(.leftCommand))
        XCTAssertFalse(modifiers.contains(.rightCommand))
        XCTAssertEqual(KeyModifiers(CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)),
                       .rightCommand)
    }

    // MARK: Return and Escape

    func testReturnConfirmsAndIsKeptFromTheApp() {
        let down = feed(.keyDown(keyCode: kVK_Return, modifiers: [], isRepeat: false), .recording)
        XCTAssertEqual(down, .init(swallow: true, gesture: .confirm))
        // The key-up goes with it, even though the capture has moved on.
        XCTAssertEqual(feed(.keyUp(keyCode: kVK_Return), .finishing), .init(swallow: true, gesture: nil))
    }

    func testKeypadEnterConfirmsToo() {
        XCTAssertEqual(feed(.keyDown(keyCode: kVK_ANSI_KeypadEnter, modifiers: .function, isRepeat: false),
                            .recording).gesture, .confirm)
    }

    func testEscapeCancels() {
        XCTAssertEqual(feed(.keyDown(keyCode: kVK_Escape, modifiers: [], isRepeat: false), .recording),
                       .init(swallow: true, gesture: .cancel))
    }

    /// Return pressed before the text has landed means "and send it": held
    /// back now, replayed after the paste.
    func testReturnWhileFinishingAsksToSend() {
        XCTAssertEqual(feed(.keyDown(keyCode: kVK_Return, modifiers: [], isRepeat: false), .finishing),
                       .init(swallow: true, gesture: .submitWhenDone))
        // Escape is not ours once the microphone is off.
        XCTAssertEqual(feed(.keyDown(keyCode: kVK_Escape, modifiers: [], isRepeat: false), .finishing),
                       .init())
    }

    /// With nothing being dictated, Return and Escape belong to the app.
    func testNothingIsCapturedWhenIdle() {
        XCTAssertEqual(feed(.keyDown(keyCode: kVK_Return, modifiers: [], isRepeat: false), .off), .init())
        XCTAssertEqual(feed(.keyUp(keyCode: kVK_Return), .off), .init())
        XCTAssertEqual(feed(.keyDown(keyCode: kVK_Escape, modifiers: [], isRepeat: false), .off), .init())
    }

    /// ⇧Return is a line break and ⌘Return is "send" in many apps: not ours.
    func testModifiedReturnPassesThrough() {
        for modifiers: KeyModifiers in [.shift, .leftCommand, .rightCommand, .option, .control] {
            XCTAssertEqual(feed(.keyDown(keyCode: kVK_Return, modifiers: modifiers, isRepeat: false), .recording),
                           .init(), "\(modifiers)")
        }
    }

    /// Ordinary typing during a dictation reaches the app.
    func testOtherKeysPassThroughWhileRecording() {
        XCTAssertEqual(feed(.keyDown(keyCode: kVK_ANSI_A, modifiers: [], isRepeat: false), .recording), .init())
    }

    /// Holding Return must not confirm twice, nor leak repeats into the app
    /// after the dictation has finished.
    func testAutoRepeatOfAHeldBackKeyStaysHeldBack() {
        XCTAssertEqual(feed(.keyDown(keyCode: kVK_Return, modifiers: [], isRepeat: false), .recording).gesture,
                       .confirm)
        XCTAssertEqual(feed(.keyDown(keyCode: kVK_Return, modifiers: [], isRepeat: true), .finishing),
                       .init(swallow: true, gesture: nil))
        XCTAssertEqual(feed(.keyDown(keyCode: kVK_Return, modifiers: [], isRepeat: true), .off),
                       .init(swallow: true, gesture: nil))
        XCTAssertTrue(feed(.keyUp(keyCode: kVK_Return), .off).swallow)
        // Released: the next Return is the app's again.
        XCTAssertEqual(feed(.keyDown(keyCode: kVK_Return, modifiers: [], isRepeat: false), .off), .init())
    }

    /// A Return that went down before the dictation started is the app's,
    /// and so is its key-up.
    func testKeyUpOfAKeyThatWasNotHeldBackPassesThrough() {
        _ = feed(.keyDown(keyCode: kVK_Return, modifiers: [], isRepeat: false), .off)
        XCTAssertFalse(feed(.keyUp(keyCode: kVK_Return), .recording).swallow)
    }
}
