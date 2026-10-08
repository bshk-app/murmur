import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// What dictation wants from the keyboard at this moment. Pushed by
/// `DictationController` whenever its state changes; read by the event tap on
/// its own thread.
enum KeyCapture: Equatable, Sendable {
    /// Nothing is held back. Only the right-⌘ tap is watched, and it is watched
    /// passively: the key still reaches the app.
    case off
    /// A tap-started dictation is listening. Return finishes it and Escape
    /// throws it away; both are kept from the app, so a Return meant for
    /// Murmur cannot also send a half-empty message in a chat.
    case recording
    /// The microphone is off and the text has not landed yet. A Return here
    /// is the user's "and send it", pressed before there was anything to send,
    /// so it is held back and replayed after the paste instead of sending the
    /// field as it is now.
    case finishing
}

enum KeyGesture: Equatable, Sendable {
    /// Right ⌘ pressed and released on its own.
    case rightCommandTap
    /// Right ⌘ has been down on its own for `KeyGestureRecognizer.holdDelay`:
    /// a hold-to-talk take beginning, or a slow tap. Sent once per press;
    /// the release says which (`.rightCommandTap` or `.rightCommandReleased`).
    case rightCommandHeld
    /// Let go after `.rightCommandHeld`, too late to be a tap: the end of a
    /// hold-to-talk take.
    case rightCommandReleased
    /// Another key, modifier or click joined a press that had already sent
    /// `.rightCommandHeld`: it was a shortcut after all, not dictation.
    case rightCommandChord
    /// Return while recording: stop and insert.
    case confirm
    /// Escape while recording: stop and insert nothing.
    case cancel
    /// Return while finishing: press Return once the text is in.
    case submitWhenDone
}

/// The modifiers the recognizer cares about, with ⌘ split by side — a lone
/// right ⌘ is the trigger, and that cannot be told apart from left ⌘ in the
/// device-independent flags.
struct KeyModifiers: OptionSet, Sendable {
    let rawValue: UInt8
    static let shift = KeyModifiers(rawValue: 1 << 0)
    static let control = KeyModifiers(rawValue: 1 << 1)
    static let option = KeyModifiers(rawValue: 1 << 2)
    static let leftCommand = KeyModifiers(rawValue: 1 << 3)
    static let rightCommand = KeyModifiers(rawValue: 1 << 4)
    static let function = KeyModifiers(rawValue: 1 << 5)

    static let command: KeyModifiers = [.leftCommand, .rightCommand]

    /// `NX_DEVICELCMDKEYMASK` / `NX_DEVICERCMDKEYMASK` from IOKit's
    /// `IOLLEvent.h`: the side-specific bits CoreGraphics carries alongside
    /// the generic ⌘ flag. Not exported to Swift.
    private static let deviceLeftCommand: UInt64 = 0x0000_0008
    private static let deviceRightCommand: UInt64 = 0x0000_0010

    init(rawValue: UInt8) { self.rawValue = rawValue }

    init(_ flags: CGEventFlags) {
        var m: KeyModifiers = []
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskSecondaryFn) { m.insert(.function) }
        if flags.contains(.maskCommand) {
            let raw = flags.rawValue
            let left = raw & Self.deviceLeftCommand != 0
            let right = raw & Self.deviceRightCommand != 0
            if left { m.insert(.leftCommand) }
            if right { m.insert(.rightCommand) }
            // A synthetic event may set ⌘ without saying which side. Treat it
            // as left: it must never pass for the trigger key.
            if !left, !right { m.insert(.leftCommand) }
        }
        self = m
    }
}

/// One keyboard or pointer event, reduced to what the recognizer decides on.
enum KeyInput: Equatable, Sendable {
    case modifiersChanged(keyCode: Int, modifiers: KeyModifiers, time: TimeInterval)
    case keyDown(keyCode: Int, modifiers: KeyModifiers, isRepeat: Bool)
    case keyUp(keyCode: Int)
    case pointerDown
}

/// Turns raw key events into dictation gestures, and says which events to
/// keep from the frontmost app.
///
/// Pure on purpose: the event tap that feeds it runs on its own thread with
/// a system-imposed time limit, and none of that can run in a unit test. Every
/// decision lives here instead, where it can.
///
/// The right-⌘ tap is "pressed and released with nothing else in between".
/// Right ⌘ is still a modifier, so ⌘C typed with the right hand, a ⌘-click or
/// a ⌘⇧ chord must not start a dictation, and a press held long enough to
/// look like second thoughts is not a tap either.
///
/// Held on its own past `holdDelay`, the press opens the microphone while
/// the key is still down - hold-to-talk. Whether it was that or a slow tap is
/// only known at release, so the controller is told both: `.rightCommandHeld`
/// when the microphone should open, then `.rightCommandTap` (keep listening,
/// Return inserts) or `.rightCommandReleased` (insert now). A shortcut that
/// arrives late (`.rightCommandChord`) throws the take away.
struct KeyGestureRecognizer {
    struct Outcome: Equatable {
        var swallow = false
        var gesture: KeyGesture?
        /// A right-⌘ press began at this time. Call `holdDelayPassed(pressedAt:)`
        /// with it once `holdDelay` has gone by: no event arrives to say a key
        /// is still being held.
        var holdCheck: TimeInterval?
    }

    /// Long enough for an unhurried tap. Let go any later and it was a
    /// hold-to-talk take, if one began (`holdDelay`), or nothing.
    static let maxTapDuration: TimeInterval = 0.6
    /// How long right ⌘ must be down on its own before the microphone opens.
    /// Most ⌘-shortcuts follow the ⌘ within this, so they never get that far;
    /// a longer wait would cut off the first word of a hold-to-talk take.
    static let holdDelay: TimeInterval = 0.3

    private var tapStartedAt: TimeInterval?
    /// `.rightCommandHeld` was sent for the press that is down now.
    private var holdReported = false
    /// Keys whose key-down was kept from the app. Their key-up and auto-repeat
    /// go with it, whatever the capture mode has become since: an app that
    /// sees half of a key press can act on the half it saw.
    private var heldBack: Set<Int> = []

    mutating func handle(_ input: KeyInput, capture: KeyCapture) -> Outcome {
        switch input {
        case let .modifiersChanged(keyCode, modifiers, time):
            return modifiersChanged(keyCode: keyCode, modifiers: modifiers, time: time)

        case let .keyDown(keyCode, modifiers, isRepeat):
            if let outcome = finishHeldTake(keyCode: keyCode, modifiers: modifiers, capture: capture) {
                return outcome
            }
            let chord = endPress()
            var outcome = keyDown(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat, capture: capture)
            // Never both: a gesture from `keyDown` needs a bare key, a chord
            // needs right ⌘ down.
            if outcome.gesture == nil { outcome.gesture = chord }
            return outcome

        case let .keyUp(keyCode):
            return Outcome(swallow: heldBack.remove(keyCode) != nil)

        case .pointerDown:
            return Outcome(gesture: endPress())
        }
    }

    /// The check `Outcome.holdCheck` asked for. `.rightCommandHeld` if that
    /// same press is still down on its own; nil if it has been released or
    /// joined by another key since, or a newer press replaced it.
    mutating func holdDelayPassed(pressedAt: TimeInterval) -> KeyGesture? {
        guard tapStartedAt == pressedAt, !holdReported else { return nil }
        holdReported = true
        return .rightCommandHeld
    }

    /// The press stops being a tap or a hold. A chord, if the controller had
    /// already been told the key was held.
    private mutating func endPress() -> KeyGesture? {
        defer { tapStartedAt = nil; holdReported = false }
        return tapStartedAt != nil && holdReported ? .rightCommandChord : nil
    }

    private mutating func modifiersChanged(keyCode: Int, modifiers: KeyModifiers,
                                           time: TimeInterval) -> Outcome {
        guard keyCode == kVK_RightCommand else {
            // Any other modifier going down or up while right ⌘ is held turns
            // the press into a chord.
            return Outcome(gesture: endPress())
        }
        if modifiers.contains(.rightCommand) {
            // With anything else already down it is a chord from the start.
            guard modifiers == .rightCommand else { return Outcome(gesture: endPress()) }
            tapStartedAt = time
            holdReported = false
            return Outcome(holdCheck: time)
        }
        let held = holdReported
        guard let start = tapStartedAt else { return Outcome() }
        tapStartedAt = nil
        holdReported = false
        // The modifier event itself still goes through: a lone ⌘ press means
        // nothing to any app, and holding back half of one could leave an app
        // believing ⌘ is still down.
        if time - start <= Self.maxTapDuration { return Outcome(gesture: .rightCommandTap) }
        return Outcome(gesture: held ? .rightCommandReleased : nil)
    }

    /// Return or Escape pressed before letting go of right ⌘ in a
    /// hold-to-talk take: they finish it the way they would after letting go,
    /// rather than counting as a ⌘-shortcut that throws the take away.
    private mutating func finishHeldTake(keyCode: Int, modifiers: KeyModifiers,
                                         capture: KeyCapture) -> Outcome? {
        guard tapStartedAt != nil, holdReported, capture == .recording,
              modifiers.subtracting(.function) == .rightCommand else { return nil }
        let gesture: KeyGesture
        switch keyCode {
        case kVK_Return, kVK_ANSI_KeypadEnter: gesture = .confirm
        case kVK_Escape: gesture = .cancel
        default: return nil
        }
        // Done with this press: letting go of the key now means nothing.
        tapStartedAt = nil
        holdReported = false
        heldBack.insert(keyCode)
        return Outcome(swallow: true, gesture: gesture)
    }

    private mutating func keyDown(keyCode: Int, modifiers: KeyModifiers, isRepeat: Bool,
                                  capture: KeyCapture) -> Outcome {
        if isRepeat, heldBack.contains(keyCode) { return Outcome(swallow: true) }
        // Only the bare key. ⇧Return, ⌘Return and the rest mean something of
        // their own in the apps people dictate into, so they pass untouched.
        guard modifiers.subtracting(.function).isEmpty else { return Outcome() }
        let gesture: KeyGesture
        switch (capture, keyCode) {
        case (.recording, kVK_Return), (.recording, kVK_ANSI_KeypadEnter):
            gesture = .confirm
        case (.recording, kVK_Escape):
            gesture = .cancel
        case (.finishing, kVK_Return), (.finishing, kVK_ANSI_KeypadEnter):
            gesture = .submitWhenDone
        default:
            return Outcome()
        }
        heldBack.insert(keyCode)
        return Outcome(swallow: true, gesture: isRepeat ? nil : gesture)
    }
}
