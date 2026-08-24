import XCTest
@testable import MurmurKit

final class TwoPassSessionTests: XCTestCase {
    /// The text that gets pasted is the batch pass, not the live draft.
    func test_finish_returns_the_batch_transcript() {
        var batched: [Float] = []
        let session = TwoPassSession(
            liveStep: { _ in },
            liveText: { "draft with errors" },
            liveFinish: {},
            batch: { samples in
                batched = samples
                return "corrected final"
            }
        )

        _ = session.step([0.1, 0.2, 0.3])
        XCTAssertEqual(session.finishText(), "corrected final")
        XCTAssertEqual(batched, [0.1, 0.2, 0.3])
    }

    /// Hotkey release must not spend more live-lane compute on leftover chunks.
    func test_release_keeps_audio_but_stops_the_live_lane() {
        var liveChunks = 0
        var liveFinished = 0
        let session = TwoPassSession(
            liveStep: { _ in liveChunks += 1 },
            liveText: { "draft" },
            liveFinish: { liveFinished += 1 },
            batch: { samples in
                XCTAssertEqual(samples, [1, 2, 3, 4])
                return "final"
            }
        )

        _ = session.step([1, 2])
        session.releaseLive()
        _ = session.step([3, 4])

        XCTAssertEqual(liveChunks, 1)
        XCTAssertEqual(session.finishText(), "final")
        XCTAssertEqual(liveFinished, 0)
    }

    /// A failed authoritative pass must not paste or auto-send an incomplete draft.
    func test_empty_batch_does_not_fall_back_to_live_text() {
        let session = TwoPassSession(
            liveStep: { _ in },
            liveText: { "incomplete draft" },
            liveFinish: {},
            batch: { _ in "" }
        )

        _ = session.step([1, 2])
        XCTAssertEqual(session.finishText(), "")
    }
}
