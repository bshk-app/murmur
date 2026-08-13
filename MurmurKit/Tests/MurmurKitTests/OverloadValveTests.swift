import XCTest
@testable import MurmurKit

final class OverloadValveTests: XCTestCase {
    /// 480 ms of audio processed in 300 ms — the pipeline is ahead.
    func test_a_pipeline_keeping_up_accrues_no_debt() {
        var v = OverloadValve(shedAboveSeconds: 1.5)
        for _ in 0 ..< 20 { v.record(compute: 0.30, audio: 0.48) }

        XCTAssertEqual(v.debtSeconds, 0, accuracy: 0.0001)
        XCTAssertFalse(v.isShedding)
    }

    func test_debt_accumulates_when_compute_exceeds_audio() {
        var v = OverloadValve(shedAboveSeconds: 1.5)
        v.record(compute: 0.68, audio: 0.48)
        v.record(compute: 0.68, audio: 0.48)

        XCTAssertEqual(v.debtSeconds, 0.40, accuracy: 0.0001)
    }

    /// Falling behind then catching up must not bank credit — being early does
    /// not buy the right to be late later.
    func test_debt_never_goes_negative() {
        var v = OverloadValve(shedAboveSeconds: 1.5)
        v.record(compute: 0.68, audio: 0.48)   // +0.20
        v.record(compute: 0.10, audio: 0.48)   // −0.38 → floors at 0

        XCTAssertEqual(v.debtSeconds, 0, accuracy: 0.0001)
    }

    func test_valve_sheds_once_debt_passes_the_threshold() {
        var v = OverloadValve(shedAboveSeconds: 1.5)
        for _ in 0 ..< 7 { v.record(compute: 0.72, audio: 0.48) }   // 7 × 0.24 = 1.68

        XCTAssertTrue(v.isShedding)
    }

    /// The accurate lane is finished, not paused: its stream cannot resume with
    /// context. So the decision latches for the rest of the utterance.
    func test_shedding_latches_even_if_the_pipeline_recovers() {
        var v = OverloadValve(shedAboveSeconds: 1.5)
        for _ in 0 ..< 7 { v.record(compute: 0.72, audio: 0.48) }
        for _ in 0 ..< 50 { v.record(compute: 0.05, audio: 0.48) }

        XCTAssertEqual(v.debtSeconds, 0, accuracy: 0.0001)
        XCTAssertTrue(v.isShedding, "recovering must not un-shed")
    }
}
