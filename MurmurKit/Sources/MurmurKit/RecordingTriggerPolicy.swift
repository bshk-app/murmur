import Foundation

public enum RecordingTriggerEvent: Sendable {
    case keyDown
    case keyUp
}

public struct RecordingTriggerState: Sendable {
    public let isRecording: Bool
    public let isActive: Bool
    public let latchedToggle: Bool
    public let isEnabled: Bool

    public init(
        isRecording: Bool,
        isActive: Bool,
        latchedToggle: Bool,
        isEnabled: Bool
    ) {
        self.isRecording = isRecording
        self.isActive = isActive
        self.latchedToggle = latchedToggle
        self.isEnabled = isEnabled
    }
}

/// Routes hotkey events for one recording lifecycle.
///
/// A running session owns the trigger mode it started with. Preferences may
/// change while the microphone is live, but they apply only to the next session;
/// otherwise key-down and key-up can each read a different mode and neither stops.
public enum RecordingTriggerPolicy {
    public static func route(
        _ event: RecordingTriggerEvent,
        state: RecordingTriggerState,
        begin: () -> Void,
        end: () -> Void
    ) {
        switch event {
        case .keyDown:
            if !state.isActive {
                if state.isEnabled { begin() }
            } else if state.isRecording, state.latchedToggle {
                end()
            }

        case .keyUp:
            if state.isRecording, !state.latchedToggle { end() }
        }
    }
}
