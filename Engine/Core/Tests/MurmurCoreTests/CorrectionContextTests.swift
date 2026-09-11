@testable import MurmurCore
import XCTest

final class CorrectionContextTests: XCTestCase {
    func test_adjacent_corrections_revisit_audio_without_losing_samples() {
        var context = CorrectionContext(maxSamples: 10)
        let first = context.append(id: 1, range: 0..<4, audio: [1, 2, 3, 4])
        let second = context.append(id: 2, range: 4..<7, audio: [5, 6, 7])
        XCTAssertEqual(first.samples, [1, 2, 3, 4])
        XCTAssertEqual(second.samples, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(second.segmentIDs, [1, 2])
        let bounded = context.append(id: 3, range: 7..<11, audio: [8, 9, 10, 11])
        XCTAssertEqual(bounded.segmentIDs, [3])
        XCTAssertEqual(bounded.samples, [8, 9, 10, 11])
    }

    func test_gap_starts_new_context_instead_of_joining_unrelated_speech() {
        var context = CorrectionContext()
        _ = context.append(id: 1, range: 0..<2, audio: [1, 2])
        let next = context.append(id: 2, range: 20..<22, audio: [3, 4])
        XCTAssertEqual(next.samples, [3, 4])
        XCTAssertEqual(next.segmentIDs, [2])
    }

    func test_revised_context_replaces_broken_word_and_preserves_next_live_phrase() {
        var transcript = CaptionTranscript()
        let a = transcript.open(startSample: 0)
        transcript.close(a, endSample: 4)
        transcript.confirm(a, text: "на уста")
        let b = transcript.open(startSample: 4)
        transcript.close(b, endSample: 8)
        let c = transcript.open(startSample: 8)
        transcript.updateProvisional(c, text: "Следующая фраза")
        transcript.confirm(b, text: "на устройстве", replacing: [a, b])
        XCTAssertEqual(transcript.snapshot().confirmed.map(\.text), ["на устройстве"])
        XCTAssertEqual(transcript.snapshot().confirmed.first?.startSample, 0)
        XCTAssertEqual(transcript.snapshot().confirmed.first?.endSample, 8)
        XCTAssertEqual(transcript.snapshot().provisional, "Следующая фраза")
        // An older task finishing later cannot restore its incomplete prefix.
        transcript.confirm(a, text: "на уста", replacing: [a])
        XCTAssertEqual(transcript.snapshot().confirmed.map(\.text), ["на устройстве"])
    }

    func test_empty_context_result_keeps_preceding_correction_and_new_draft() {
        var transcript = CaptionTranscript()
        let a = transcript.open(startSample: 0)
        transcript.close(a, endSample: 4)
        transcript.confirm(a, text: "первый")
        let b = transcript.open(startSample: 4)
        transcript.updateProvisional(b, text: "второй")
        transcript.close(b, endSample: 8)
        transcript.confirm(b, text: "", replacing: [a, b])
        XCTAssertEqual(transcript.snapshot().confirmed.map(\.text), ["первый", "второй"])
    }

    func test_later_group_keeps_preceding_group_and_replaces_repeated_context() {
        var transcript = CaptionTranscript()
        let a = transcript.open(startSample: 0); transcript.close(a, endSample: 4)
        let b = transcript.open(startSample: 4); transcript.close(b, endSample: 8)
        transcript.confirm(b, text: "один два", replacing: [a, b])
        let c = transcript.open(startSample: 8); transcript.close(c, endSample: 12)
        transcript.confirm(c, text: "один два три", replacing: [a, b, c])
        XCTAssertEqual(transcript.snapshot().confirmed.map(\.text), ["один два три"])
        XCTAssertEqual(transcript.snapshot().confirmed.first?.startSample, 0)
        let d = transcript.open(startSample: 20); transcript.close(d, endSample: 24)
        transcript.confirm(d, text: "другая фраза", replacing: [d])
        XCTAssertEqual(transcript.snapshot().confirmed.map(\.text), ["один два три", "другая фраза"])
    }
}
