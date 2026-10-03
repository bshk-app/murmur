import XCTest
@testable import Murmur
@testable import MurmurKit

/// The popover's Start/Stop: without it a speaker with no shortcut to hand
/// (a clicker, a borrowed laptop) could not run Murmur at all.
@MainActor
final class MenuStartStopTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private let keys = [AppMode.defaultsKey, TriggerMode.defaultsKey]

    override func setUpWithError() throws {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        // Hold is the case where a click differs from the hotkey: there is no key to release.
        UserDefaults.standard.set(TriggerMode.hold.rawValue, forKey: TriggerMode.defaultsKey)
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

    private func controller(mode: AppMode) -> (DictationController, FakeDictationSession) {
        UserDefaults.standard.set(mode.rawValue, forKey: AppMode.defaultsKey)
        let controller = DictationController()
        let fake = FakeDictationSession()
        controller.session = fake
        return (controller, fake)
    }

    func testTheMenuStartsAndStopsCaptions() async {
        let (controller, fake) = controller(mode: .captions)

        controller.toggleFromMenu()
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertEqual(controller.state, .recording)

        controller.toggleFromMenu()
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertNotEqual(controller.state, .recording)
    }

    /// Latched as hold, the HUD would show no Stop button and only a key
    /// release - of a key nobody pressed - could end the dictation.
    func testAMenuStartEndsOnATapEvenInHoldMode() async {
        let (controller, _) = controller(mode: .dictation)

        controller.toggleFromMenu()
        await controller.recordingTask?.value

        XCTAssertEqual(controller.state, .recording)
        XCTAssertTrue(controller.latchedToggle)
    }
}
