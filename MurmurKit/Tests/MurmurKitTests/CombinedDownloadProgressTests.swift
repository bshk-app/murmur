import XCTest
@testable import MurmurKit

final class CombinedDownloadProgressTests: XCTestCase {
    /// The regression this guards: weighting each leg equally. With legs of
    /// 17 and 43 MB, finishing the first is 28% of the work, not 50%.
    func testPivotLegsAreWeightedByBytesNotCount() {
        let combined = CombinedDownloadProgress(legBytes: [17_000_000, 43_000_000])
        XCTAssertEqual(combined.totalBytes, 60_000_000)

        // First leg complete == start of the second.
        let boundary = combined.at(leg: 1, received: 0)
        XCTAssertEqual(boundary.receivedBytes, 17_000_000)
        XCTAssertEqual(boundary.fraction, 17.0 / 60.0, accuracy: 0.0001)
        XCTAssertNotEqual(boundary.fraction, 0.5, accuracy: 0.01,
                          "legs weighted by count instead of bytes")

        // Byte counters are cumulative, so the label never resets mid-pivot.
        let midSecond = combined.at(leg: 1, received: 21_500_000)
        XCTAssertEqual(midSecond.receivedBytes, 38_500_000)
        XCTAssertGreaterThan(midSecond.fraction, boundary.fraction)

        let end = combined.at(leg: 2, received: 0)
        XCTAssertEqual(end.fraction, 1.0, accuracy: 0.0001)
    }

    func testCombinedProgressClampsHostileInput() {
        let combined = CombinedDownloadProgress(legBytes: [100, 100])
        // A mirror re-compressing the same verified content may send more than
        // pinned; the bar must not exceed 1.0.
        XCTAssertEqual(combined.at(leg: 1, received: 999).fraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(combined.at(leg: 0, received: -5).receivedBytes, 0)
        XCTAssertEqual(CombinedDownloadProgress(legBytes: []).at(leg: 0, received: 10).fraction, 0)
    }

}
