import XCTest
@testable import MurmurKit

final class RecordingTriggerPolicyTests: XCTestCase {
    private func actions(
        event: RecordingTriggerEvent,
        isRecording: Bool,
        isActive: Bool,
        latchedToggle: Bool,
        isEnabled: Bool = true
    ) -> [String] {
        var actions: [String] = []
        RecordingTriggerPolicy.route(
            event,
            state: RecordingTriggerState(
                isRecording: isRecording,
                isActive: isActive,
                latchedToggle: latchedToggle,
                isEnabled: isEnabled
            ),
            begin: { actions.append("begin") },
            end: { actions.append("end") }
        )
        return actions
    }

    /// A toggle session remains tap-to-stop even if the persisted setting changes
    /// to Hold while the microphone is live.
    func test_active_toggle_session_stops_on_key_down() {
        XCTAssertEqual(
            actions(event: .keyDown, isRecording: true, isActive: true, latchedToggle: true),
            ["end"]
        )
        XCTAssertEqual(
            actions(event: .keyUp, isRecording: true, isActive: true, latchedToggle: true),
            []
        )
    }

    /// A hold session ignores repeated key-down and still stops on key-up if the
    /// persisted setting changes to Toggle in flight.
    func test_active_hold_session_stops_on_key_up() {
        XCTAssertEqual(
            actions(event: .keyDown, isRecording: true, isActive: true, latchedToggle: false),
            []
        )
        XCTAssertEqual(
            actions(event: .keyUp, isRecording: true, isActive: true, latchedToggle: false),
            ["end"]
        )
    }

    /// With no session to preserve, key-down starts one and key-up is inert. The
    /// current preference is latched by beginRecording for all later events.
    func test_idle_key_down_begins_one_session() {
        XCTAssertEqual(
            actions(event: .keyDown, isRecording: false, isActive: false, latchedToggle: false),
            ["begin"]
        )
        XCTAssertEqual(
            actions(event: .keyUp, isRecording: false, isActive: false, latchedToggle: false),
            []
        )
    }

    /// During asynchronous finalisation, neither direction can start or stop a
    /// second session.
    func test_transcribing_session_ignores_both_events() {
        XCTAssertEqual(
            actions(event: .keyDown, isRecording: false, isActive: true, latchedToggle: true),
            []
        )
        XCTAssertEqual(
            actions(event: .keyUp, isRecording: false, isActive: true, latchedToggle: true),
            []
        )
    }

    /// Turning off Murmur while a toggle session is live must not disable its only
    /// hotkey stop path. Disabled blocks new sessions, never cleanup of one already
    /// holding the microphone.
    func test_disabled_master_still_allows_active_stop_but_blocks_begin() {
        XCTAssertEqual(
            actions(
                event: .keyDown,
                isRecording: true,
                isActive: true,
                latchedToggle: true,
                isEnabled: false
            ),
            ["end"]
        )
        XCTAssertEqual(
            actions(
                event: .keyDown,
                isRecording: false,
                isActive: false,
                latchedToggle: true,
                isEnabled: false
            ),
            []
        )
    }
}
