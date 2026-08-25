import XCTest
@testable import MurmurKit

final class StopPresentationTests: XCTestCase {
    /// The gesture already said "done": nothing may hold the screen afterwards.
    func test_typed_transcript_dismisses_immediately() {
        let policy = StopPresentation.policy(for: .typed, textIsEmpty: false)
        XCTAssertEqual(policy, .dismiss)
        XCTAssertEqual(policy.linger, 0)
    }

    /// Captions type nothing, but the user still pressed stop.
    func test_captions_dismiss_immediately() {
        XCTAssertEqual(StopPresentation.policy(for: .displayedOnly, textIsEmpty: false), .dismiss)
    }

    /// Undelivered text lives only in the overlay, so it stays — with the reason.
    func test_failed_delivery_keeps_the_text_and_says_why() {
        let policy = StopPresentation.policy(for: .failed("Secure input is on"), textIsEmpty: false)
        XCTAssertEqual(policy.linger, StopPresentation.undeliveredLinger)
        XCTAssertTrue(policy.showsText)
        XCTAssertEqual(policy.message, "Secure input is on")
    }

    /// A failure with nothing to show is not worth six seconds of screen.
    func test_failed_delivery_of_empty_text_dismisses() {
        XCTAssertEqual(StopPresentation.policy(for: .failed("nope"), textIsEmpty: true), .dismiss)
    }
}
