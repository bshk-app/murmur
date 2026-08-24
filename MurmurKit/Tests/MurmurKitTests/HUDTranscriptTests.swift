import XCTest
@testable import MurmurKit

final class HUDTranscriptTests: XCTestCase {
    func test_text_within_budget_passes_through_unchanged() {
        let t = HUDTranscript.clamped(confirmed: "привет как дела", partial: "у меня", maxChars: 145)

        XCTAssertEqual(t.confirmed, "привет как дела")
        XCTAssertEqual(t.partial, "у меня")
        XCTAssertFalse(t.truncated)
    }

    func test_overlong_confirmed_is_cut_and_flagged() {
        // 30 chars of confirmed into a 20-char budget.
        let t = HUDTranscript.clamped(confirmed: "один два три четыре пять шесть", partial: "", maxChars: 20)

        XCTAssertTrue(t.truncated)
        XCTAssertLessThanOrEqual(t.confirmed.count, 20)
    }

    func test_cut_lands_on_a_word_boundary() {
        // A char-wise suffix would start mid-word ("ри четыре пять шесть").
        let t = HUDTranscript.clamped(confirmed: "один два три четыре пять шесть", partial: "", maxChars: 20)

        XCTAssertEqual(t.confirmed, "четыре пять шесть")
    }

    func test_partial_survives_whole_while_confirmed_gives_way() {
        // 12 + 1 + 11 = 24 chars rendered, into a 20-char budget.
        let t = HUDTranscript.clamped(confirmed: "один два три", partial: "четыре пять", maxChars: 20)

        XCTAssertEqual(t.partial, "четыре пять", "the newest words must never be cut")
        XCTAssertTrue(t.truncated)
        XCTAssertLessThanOrEqual(t.confirmed.count + 1 + t.partial.count, 20)
    }

    func test_overlong_partial_is_cut_itself_and_confirmed_disappears() {
        // 26 chars of partial alone overflow the 20-char budget.
        let t = HUDTranscript.clamped(confirmed: "один два", partial: "три четыре пять шесть семь", maxChars: 20)

        XCTAssertEqual(t.confirmed, "")
        XCTAssertLessThanOrEqual(t.partial.count, 20)
        XCTAssertTrue(t.truncated)
    }

    func test_a_single_word_longer_than_the_budget_still_shows() {
        // No whole word fits. Showing nothing is worse than overflowing by one word —
        // `.lineLimit` is the layout guard, this function only decides what to show.
        let t = HUDTranscript.clamped(confirmed: "", partial: "человеконенавистничество", maxChars: 20)

        XCTAssertEqual(t.partial, "человеконенавистничество")
    }

    /// Regression guard, not a driver — it passes against the implementation as built.
    func test_empty_input_is_left_alone() {
        let t = HUDTranscript.clamped(confirmed: "", partial: "", maxChars: 145)

        XCTAssertEqual(t, HUDTranscript(confirmed: "", partial: "", truncated: false))
    }
}
