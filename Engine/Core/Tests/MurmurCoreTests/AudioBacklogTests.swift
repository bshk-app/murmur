import XCTest
@testable import MurmurCore

final class AudioBacklogTests: XCTestCase {
    func testCapPreservesAcceptedFramesAndReportsOverflowOnlyOnce() {
        let backlog = AudioBacklog(maximumSamples: 10)
        let token = backlog.reset()
        XCTAssertEqual(backlog.admit(6, generation: token), .accepted)
        XCTAssertEqual(backlog.admit(4, generation: token), .accepted)
        XCTAssertEqual(backlog.admit(1, generation: token), .overloaded)
        XCTAssertEqual(backlog.pendingSamples, 10)
        backlog.release(6, generation: token)
        XCTAssertEqual(backlog.pendingSamples, 4)
        XCTAssertEqual(backlog.admit(1, generation: token), .closed)
        backlog.release(4, generation: token)
        XCTAssertEqual(backlog.pendingSamples, 0)
    }

    func testReleaseMakesRoomBeforeOverflow() {
        let backlog = AudioBacklog(maximumSamples: 10)
        let token = backlog.reset()
        XCTAssertEqual(backlog.admit(10, generation: token), .accepted)
        backlog.release(7, generation: token)
        XCTAssertEqual(backlog.admit(7, generation: token), .accepted)
        XCTAssertEqual(backlog.pendingSamples, 10)
    }

    func testResetRejectsStaleAdmissionReleaseAndClose() {
        let backlog = AudioBacklog(maximumSamples: 10)
        let old = backlog.reset()
        XCTAssertEqual(backlog.admit(10, generation: old), .accepted)
        let current = backlog.reset()
        XCTAssertEqual(backlog.pendingSamples, 0)
        XCTAssertEqual(backlog.admit(5, generation: current), .accepted)
        backlog.release(10, generation: old)
        backlog.close(generation: old)
        XCTAssertEqual(backlog.pendingSamples, 5)
        XCTAssertEqual(backlog.admit(1, generation: old), .closed)
        XCTAssertEqual(backlog.admit(5, generation: current), .accepted)
    }

    func testCloseDrainsAcceptedWorkAndDefaultIsTenSeconds() {
        let backlog = AudioBacklog()
        XCTAssertEqual(backlog.maximumSamples, 10 * 16_000)
        let token = backlog.reset()
        XCTAssertEqual(backlog.admit(1536, generation: token), .accepted)
        backlog.close(generation: token)
        XCTAssertEqual(backlog.admit(1536, generation: token), .closed)
        backlog.release(1536, generation: token)
        XCTAssertEqual(backlog.pendingSamples, 0)
    }
}
