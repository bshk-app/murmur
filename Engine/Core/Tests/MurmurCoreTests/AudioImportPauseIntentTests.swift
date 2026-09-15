import XCTest
@testable import MurmurCore

final class AudioImportPauseIntentTests: XCTestCase {
    func testLeavingTheAppResumesByItself() {
        var intent = AudioImportPauseIntent()
        intent.paused(userInitiated: false)
        XCTAssertTrue(intent.resumesAutomatically)
    }

    func testATapStopsTheImportForGood() {
        var intent = AudioImportPauseIntent()
        intent.paused(userInitiated: true)
        XCTAssertFalse(intent.resumesAutomatically)
    }

    /// Backgrounding right after the tap must not read as the system pausing it.
    func testLeavingTheAppAfterATapKeepsItStopped() {
        var intent = AudioImportPauseIntent()
        intent.paused(userInitiated: true)
        intent.paused(userInitiated: false)
        XCTAssertFalse(intent.resumesAutomatically)
    }

    func testStartingAgainClearsTheTap() {
        var intent = AudioImportPauseIntent()
        intent.paused(userInitiated: true)
        intent.started()
        XCTAssertTrue(intent.resumesAutomatically)
        intent.paused(userInitiated: false)
        XCTAssertTrue(intent.resumesAutomatically)
    }

    func testAnImportThatWasNeverPausedResumes() {
        XCTAssertTrue(AudioImportPauseIntent().resumesAutomatically)
    }
}
