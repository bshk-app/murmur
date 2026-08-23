import XCTest
@testable import MurmurKit

final class CaptionTranscriptTests: XCTestCase {
    /// The live draft is one whole provisional segment, not a word-merged tail.
    func test_provisional_segment_carries_the_live_draft() {
        var transcript = CaptionTranscript()
        let id = transcript.open(startSample: 0)
        transcript.updateProvisional(id, text: "сегодня мы рассмотрим")

        XCTAssertEqual(transcript.snapshot().provisional, "сегодня мы рассмотрим")
        XCTAssertTrue(transcript.snapshot().confirmed.isEmpty)
    }

    /// The batch pass replaces its segment entirely — that is what keeps a
    /// mid-sentence pause from duplicating words the batch already confirmed.
    func test_correction_replaces_the_whole_segment() {
        var transcript = CaptionTranscript()
        let first = transcript.open(startSample: 0)
        transcript.updateProvisional(first, text: "сегодня мы расмотрим")
        transcript.close(first, endSample: 16_000)
        transcript.confirm(first, text: "Сегодня мы рассмотрим")

        let second = transcript.open(startSample: 16_000)
        transcript.updateProvisional(second, text: "новую архетектуру")

        let snapshot = transcript.snapshot()
        XCTAssertEqual(snapshot.confirmed.map(\.text), ["Сегодня мы рассмотрим"])
        XCTAssertEqual(snapshot.provisional, "новую архетектуру")
        XCTAssertFalse(snapshot.confirmed.contains { $0.text.contains("расмотрим") })
    }

    /// A late batch result addresses its own id, so it cannot land on the
    /// phrase that has since started.
    func test_late_correction_cannot_overwrite_a_later_segment() {
        var transcript = CaptionTranscript()
        let first = transcript.open(startSample: 0)
        transcript.close(first, endSample: 16_000)
        let second = transcript.open(startSample: 16_000)
        transcript.updateProvisional(second, text: "вторая фраза")

        transcript.confirm(first, text: "Первая фраза")

        let snapshot = transcript.snapshot()
        XCTAssertEqual(snapshot.confirmed.map(\.text), ["Первая фраза"])
        XCTAssertEqual(snapshot.provisional, "вторая фраза")
    }

    /// Captions run for an hour: confirmed history is bounded.
    func test_confirmed_history_is_trimmed_oldest_first() {
        var transcript = CaptionTranscript()
        for index in 0 ..< 5 {
            let id = transcript.open(startSample: index * 16_000)
            transcript.close(id, endSample: (index + 1) * 16_000)
            transcript.confirm(id, text: "фраза \(index)")
        }

        transcript.trimConfirmed(keep: 2)

        XCTAssertEqual(transcript.snapshot().confirmed.map(\.text), ["фраза 3", "фраза 4"])
    }

    /// A failed batch pass leaves the draft visible — captions show something.
    func test_empty_correction_keeps_the_draft() {
        var transcript = CaptionTranscript()
        let id = transcript.open(startSample: 0)
        transcript.updateProvisional(id, text: "черновик")
        transcript.close(id, endSample: 16_000)
        transcript.confirm(id, text: "   ")

        XCTAssertEqual(transcript.snapshot().confirmed.map(\.text), ["черновик"])
    }
}
