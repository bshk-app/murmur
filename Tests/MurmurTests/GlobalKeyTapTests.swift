import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import Murmur

/// The tap's own bookkeeping, fed synthetic events without installing it -
/// installing needs Accessibility and would capture the developer's keyboard.
final class GlobalKeyTapTests: XCTestCase {
    private let tap = GlobalKeyTap { _ in }

    /// A key event as if typed on the keyboard (another process), unless
    /// `pid` says otherwise.
    private func key(_ code: Int, down: Bool,
                     pid: Int32 = 1) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down))
        event.flags = []
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(pid))
        return event
    }

    private func press(_ code: Int) throws -> (down: Bool, up: Bool) {
        (tap.handle(type: .keyDown, event: try key(code, down: true)),
         tap.handle(type: .keyUp, event: try key(code, down: false)))
    }

    /// The reviewer's race: the second Return is swallowed on the tap thread,
    /// but its gesture reaches the main thread only after the paste went out.
    /// The paste asks the tap directly, so that Return still sends.
    func testAReturnHeldBackAsTheTextLandsIsNotLost() throws {
        tap.setCapture(.recording)
        XCTAssertEqual(try press(kVK_Return).down, true, "the confirming Return is Murmur's")
        // The controller has not caught up yet; the tap already counts this
        // one as "and send it".
        XCTAssertEqual(try press(kVK_Return).down, true)

        XCTAssertTrue(tap.endCapture())
        XCTAssertFalse(tap.endCapture(), "reported once, not again for the next paste")
        XCTAssertEqual(try press(kVK_Return).down, false, "after the paste, Return is the app's")
    }

    /// A session that ended without pasting must not send the next one.
    func testAStaleSendRequestDiesWithItsSession() throws {
        tap.setCapture(.finishing)
        _ = try press(kVK_Return)
        tap.setCapture(.off)
        tap.setCapture(.recording)
        XCTAssertFalse(tap.endCapture())
    }

    func testEscapeReleasesReturnAtOnce() throws {
        tap.setCapture(.recording)
        XCTAssertEqual(try press(kVK_Escape).down, true)
        XCTAssertEqual(try press(kVK_Return).down, false,
                       "nothing is coming after Escape, so the next Return must reach the app")
    }

    /// Murmur's own ⌘V and Return are how the text gets in; holding them
    /// back would undo the feature.
    func testOurOwnSyntheticKeysPassThrough() throws {
        tap.setCapture(.finishing)
        let own = try key(kVK_Return, down: true, pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(tap.handle(type: .keyDown, event: own))
        XCTAssertFalse(tap.endCapture())
    }
}
