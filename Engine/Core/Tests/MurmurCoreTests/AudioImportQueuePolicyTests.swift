import XCTest
@testable import MurmurCore

final class AudioImportQueuePolicyTests: XCTestCase {
    func testOnlyTheOldestExplicitlyQueuedImportStarts() {
        let first = UUID(), second = UUID()
        let waiting = [AudioImportQueuePolicy.Waiting(id: second, queuedAt: Date(timeIntervalSince1970: 20)), .init(id: first, queuedAt: Date(timeIntervalSince1970: 10))]
        XCTAssertEqual(AudioImportQueuePolicy.next(activeID: nil, receiving: false, suspended: false, foreground: true, waiting: waiting), first)
        XCTAssertNil(AudioImportQueuePolicy.next(activeID: first, receiving: false, suspended: false, foreground: true, waiting: waiting))
    }
    func testPauseBackgroundAndReceiptBlockAutomaticContinuation() {
        let waiting = [AudioImportQueuePolicy.Waiting(id: UUID(), queuedAt: .now)]
        XCTAssertNil(AudioImportQueuePolicy.next(activeID: nil, receiving: false, suspended: true, foreground: true, waiting: waiting))
        XCTAssertNil(AudioImportQueuePolicy.next(activeID: nil, receiving: false, suspended: false, foreground: false, waiting: waiting))
        XCTAssertNil(AudioImportQueuePolicy.next(activeID: nil, receiving: true, suspended: false, foreground: true, waiting: waiting))
        XCTAssertNil(AudioImportQueuePolicy.next(activeID: nil, receiving: false, suspended: false, foreground: true, waiting: []))
    }
}
