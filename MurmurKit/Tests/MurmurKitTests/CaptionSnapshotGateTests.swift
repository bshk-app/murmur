import XCTest
@testable import MurmurKit

final class CaptionSnapshotGateTests: XCTestCase {
    /// Mic chunks arrive every 96 ms, but silence leaves the transcript revision at
    /// zero. Only a changed revision is worth a MainActor task and a SwiftUI update.
    func test_emits_each_revision_once() {
        var gate = CaptionSnapshotGate()
        let session = gate.beginSession()

        XCTAssertFalse(gate.shouldEmit(session: session, revision: 0),
                       "initial silence was sent to the UI")
        XCTAssertTrue(gate.shouldEmit(session: session, revision: 1),
                      "the first changed caption was dropped")
        XCTAssertFalse(gate.shouldEmit(session: session, revision: 1),
                       "an unchanged caption was sent twice")
        XCTAssertTrue(gate.shouldEmit(session: session, revision: 2),
                      "a later correction was dropped")
    }

    /// A new session starts at revision zero even if its first visible snapshot
    /// happens to equal or exceed the previous talk's revision.
    func test_session_token_resets_revision_and_rejects_stale_callbacks() {
        var gate = CaptionSnapshotGate()
        let first = gate.beginSession()
        XCTAssertTrue(gate.shouldEmit(session: first, revision: 4))

        let second = gate.beginSession()

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(gate.shouldEmit(session: second, revision: 0))
        XCTAssertTrue(gate.shouldEmit(session: second, revision: 4),
                      "a matching revision from a new session was dropped")
        XCTAssertFalse(gate.shouldEmit(session: first, revision: 5),
                       "a callback from the stopped session reached the UI")
    }
}
