import XCTest
@testable import MurmurKit

final class TextInjectorPayloadTests: XCTestCase {
    func test_plain_dictation_keeps_a_trailing_space_for_the_next_utterance() {
        XCTAssertEqual(TextInjector.payload("привет", submit: false), "привет ")
    }

    func test_submitting_drops_the_trailing_space() {
        // The space exists to butt the next utterance against this one. Pressing
        // Return ends the message, so it would only travel as trailing whitespace.
        XCTAssertEqual(TextInjector.payload("привет", submit: true), "привет")
    }
}
