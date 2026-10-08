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
struct KeyGestureRecognizer {
    struct Outcome: Equatable {
        var swallow = false
        var gesture: KeyGesture?
    }

    /// Long enough for an unhurried tap, short enough that resting a thumb on
    /// the key and changing your mind does not open the microphone.
    static let maxTapDuration: TimeInterval = 0.6

    private var tapStartedAt: TimeInterval?
    /// Keys whose key-down was kept from the app. Their key-up and auto-repeat
    /// go with it, whatever the capture mode has become since: an app that
    /// sees half of a key press can act on the half it saw.
    private var heldBack: Set<Int> = []

    mutating func handle(_ input: KeyInput, capture: KeyCapture) -> Outcome {
        switch input {
        case let .modifiersChanged(keyCode, modifiers, time):
            return modifiersChanged(keyCode: keyCode, modifiers: modifiers, time: time)

        case let .keyDown(keyCode, modifiers, isRepeat):
            tapStartedAt = nil
            return keyDown(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat, capture: capture)

        case let .keyUp(keyCode):
            return Outcome(swallow: heldBack.remove(keyCode) != nil)

        case .pointerDown:
            tapStartedAt = nil
            return Outcome()
        }
    }

    private mutating func modifiersChanged(keyCode: Int, modifiers: KeyModifiers,
                                           time: TimeInterval) -> Outcome {
        guard keyCode == kVK_RightCommand else {
            // Any other modifier going down or up while right ⌘ is held turns
            // the press into a chord.
            tapStartedAt = nil
            return Outcome()
        }
        if modifiers.contains(.rightCommand) {
            tapStartedAt = modifiers == .rightCommand ? time : nil
            return Outcome()
        }
        defer { tapStartedAt = nil }
        guard let start = tapStartedAt, time - start <= Self.maxTapDuration else {
            return Outcome()
        }
        // The modifier event itself still goes through: a lone ⌘ press means
        // nothing to any app, and holding back half of one could leave an app
        // believing ⌘ is still down.
        return Outcome(gesture: .rightCommandTap)
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
