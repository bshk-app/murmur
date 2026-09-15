import XCTest
@testable import MurmurCore

final class BackgroundTranscriptionPolicyTests: XCTestCase {
    private func estimate(audio: Double, factor: Double = 0.2, load: Double = 0.3) -> BackgroundTranscriptionPolicy.Estimate {
        .init(audioSeconds: audio, realTimeFactor: factor, modelLoadSeconds: load)
    }

    func testAShortNoteOnAWarmModelIsWorthStarting() {
        XCTAssertTrue(BackgroundTranscriptionPolicy.fitsInBackground(estimate(audio: 20), budgetSeconds: 28))
    }

    /// Being cut off mid-way costs a wasted model load and leaves the note
    /// half-done, so the estimate has to clear the budget with room to spare.
    func testWorkThatOnlyJustFitsIsLeftForTheForeground() {
        // 12 s of loading plus 10 s of decoding is 22 s: under 28, over the margin.
        XCTAssertFalse(BackgroundTranscriptionPolicy.fitsInBackground(
            estimate(audio: 50, factor: 0.2, load: 12), budgetSeconds: 28))
    }

    func testALongRecordingIsNeverStartedInTheBackground() {
        XCTAssertFalse(BackgroundTranscriptionPolicy.fitsInBackground(estimate(audio: 600), budgetSeconds: 28))
    }

    func testAColdModelEatsTheBudgetOnItsOwn() {
        XCTAssertFalse(BackgroundTranscriptionPolicy.fitsInBackground(
            estimate(audio: 5, factor: 0.2, load: 12), budgetSeconds: 14))
    }

    func testNothingStartsWithoutABudget() {
        XCTAssertFalse(BackgroundTranscriptionPolicy.fitsInBackground(estimate(audio: 5), budgetSeconds: 0))
    }

    /// An unreadable or empty recording has nothing to estimate from; the
    /// foreground path reports the failure where it can be seen.
    func testAnUnmeasurableRecordingIsLeftForTheForeground() {
        XCTAssertFalse(BackgroundTranscriptionPolicy.fitsInBackground(estimate(audio: 0), budgetSeconds: 28))
    }

    // MARK: - What the phone learns from each run

    func testTheFirstMeasurementIsTakenAsIs() {
        var learned = SpeechTimings()
        learned.record(audioSeconds: 30, decodeSeconds: 6, loadSeconds: 12)
        XCTAssertEqual(learned.realTimeFactor, 0.2, accuracy: 0.001)
        XCTAssertEqual(learned.modelLoadSeconds, 12, accuracy: 0.001)
    }

    /// Later runs move the estimate rather than replace it, so one slow run under
    /// memory pressure does not park every future note in the foreground.
    func testLaterMeasurementsMoveTheEstimateGradually() {
        var learned = SpeechTimings()
        learned.record(audioSeconds: 30, decodeSeconds: 6, loadSeconds: 12)
        learned.record(audioSeconds: 30, decodeSeconds: 12, loadSeconds: 12)
        XCTAssertGreaterThan(learned.realTimeFactor, 0.2)
        XCTAssertLessThan(learned.realTimeFactor, 0.4)
    }

    func testAMeasurementWithoutAudioIsIgnored() {
        var learned = SpeechTimings()
        learned.record(audioSeconds: 30, decodeSeconds: 6, loadSeconds: 12)
        learned.record(audioSeconds: 0, decodeSeconds: 99, loadSeconds: 99)
        XCTAssertEqual(learned.realTimeFactor, 0.2, accuracy: 0.001)
    }

    /// Before anything has been measured the defaults must be pessimistic enough
    /// that the very first background attempt is not a coin toss.
    func testUnmeasuredDefaultsKeepTheFirstNoteInTheForeground() {
        let fresh = SpeechTimings()
        XCTAssertFalse(BackgroundTranscriptionPolicy.fitsInBackground(
            .init(audioSeconds: 20, realTimeFactor: fresh.realTimeFactor, modelLoadSeconds: fresh.modelLoadSeconds),
            budgetSeconds: 28))
    }
}
