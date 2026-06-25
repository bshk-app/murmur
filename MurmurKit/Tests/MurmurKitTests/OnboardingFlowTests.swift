import XCTest
@testable import MurmurKit

final class OnboardingFlowTests: XCTestCase {
    func test_steps_are_six_in_order() {
        XCTAssertEqual(OnboardingFlow.Step.allCases,
                       [.welcome, .permissions, .shortcut, .download, .tryIt, .done])
    }

    func test_permissions_gate_requires_mic_only() {
        var s = OnboardingFlow.State()
        s.step = .permissions
        XCTAssertFalse(OnboardingFlow.canContinue(s))     // no mic
        s.micGranted = true
        XCTAssertTrue(OnboardingFlow.canContinue(s))       // mic alone unblocks (accessibility skippable)
    }

    func test_download_gate_requires_both_models() {
        var s = OnboardingFlow.State()
        s.step = .download
        s.fastFraction = 1; s.accurateFraction = 0.5
        XCTAssertFalse(OnboardingFlow.canContinue(s))
        s.accurateFraction = 1
        XCTAssertTrue(OnboardingFlow.canContinue(s))
    }

    func test_tryit_gate_requires_a_success() {
        var s = OnboardingFlow.State()
        s.step = .tryIt
        XCTAssertFalse(OnboardingFlow.canContinue(s))
        s.didTry = true
        XCTAssertTrue(OnboardingFlow.canContinue(s))
    }

    func test_other_steps_never_block() {
        for step in [OnboardingFlow.Step.welcome, .shortcut, .done] {
            var s = OnboardingFlow.State(); s.step = step
            XCTAssertTrue(OnboardingFlow.canContinue(s))
        }
    }

    func test_download_math() {
        let m = OnboardingFlow.downloadMetrics(fast: 1.0, accurate: 0.5)
        XCTAssertEqual(m.downloadedGB, 0.6 * 1.0 + 3.0 * 0.5, accuracy: 0.001)   // 2.1
        XCTAssertEqual(m.totalGB, 3.6, accuracy: 0.001)
        XCTAssertFalse(m.done)
        let done = OnboardingFlow.downloadMetrics(fast: 1, accurate: 1)
        XCTAssertTrue(done.done)
        XCTAssertEqual(done.remainingGB, 0, accuracy: 0.001)
    }

    func test_next_and_back_clamp() {
        XCTAssertEqual(OnboardingFlow.next(.welcome), .permissions)
        XCTAssertEqual(OnboardingFlow.next(.done), .done)        // clamps
        XCTAssertEqual(OnboardingFlow.back(.permissions), .welcome)
        XCTAssertEqual(OnboardingFlow.back(.welcome), .welcome)  // clamps
    }
}
