import XCTest
@testable import MurmurKit

/// Records what the live lane was asked to do, so the tests can assert on epoch
/// lifetime — the thing that decides whether captions keep up for an hour.
///
/// `text` is **cumulative for the epoch**, like a real streaming model: it grows
/// with every fed chunk and only resets when the epoch does. A fake that returned
/// just the newest chunk would hide every double-render bug across a forced cap.
private final class FakeLiveLane {
    var epochs = 0
    var finishes = 0
    var chunks: [[Float]] = []
    var fedSamples: Int { chunks.reduce(0) { $0 + $1.count } }
    var words: [String] = []

    var text: String { words.joined(separator: " ") }

    func make() -> CaptionEngine.LiveLane {
        CaptionEngine.LiveLane(
            begin: { [self] in epochs += 1; words = [] },
            step: { [self] chunk in chunks.append(chunk); words.append("w\(words.count + 1)") },
            text: { [self] in text },
            finish: { [self] in finishes += 1 }
        )
    }
}

final class CaptionEngineTests: XCTestCase {
    private let chunk = [Float](repeating: 0, count: 1_536)  // 96 ms

    private func makeEngine(
        live: FakeLiveLane,
        speech: @escaping ([Float]) -> Bool,
        batch: @escaping (Range<Int>, [Float]) -> String = { range, _ in "batch \(range.lowerBound)" },
        maxEpochSeconds: Double = 60
    ) -> CaptionEngine {
        CaptionEngine(
            live: live.make(),
            isSpeech: speech,
            batch: batch,
            endpointSilence: 0.48,
            preRoll: 0.288,
            maxEpochSeconds: maxEpochSeconds
        )
    }

    /// While a phrase is open every sample reaches the live lane: its streaming
    /// state is only continuous if nothing is withheld.
    func test_no_sample_is_withheld_while_a_phrase_is_open() {
        let live = FakeLiveLane()
        let engine = makeEngine(live: live, speech: { _ in true })

        for _ in 0 ..< 10 { engine.step(chunk) }

        XCTAssertEqual(live.fedSamples, 10 * chunk.count)
    }

    /// Silence before any speech opens nothing: a live epoch is worth its cost
    /// only once there is speech to draft.
    func test_silence_before_speech_opens_no_epoch() {
        let live = FakeLiveLane()
        let engine = makeEngine(live: live, speech: { _ in false })

        for _ in 0 ..< 10 { engine.step(chunk) }

        XCTAssertEqual(live.epochs, 0)
        XCTAssertEqual(live.fedSamples, 0)
    }

    /// A real pause closes the phrase and corrects it. The next epoch starts when
    /// the speaker does — not while the room is still quiet.
    func test_endpoint_confirms_the_phrase_and_defers_the_next_epoch() {
        let live = FakeLiveLane()
        var speaking = true
        let engine = makeEngine(live: live, speech: { _ in speaking })

        for _ in 0 ..< 10 { engine.step(chunk) }   // ~1 s of speech
        XCTAssertEqual(live.epochs, 1)

        speaking = false
        for _ in 0 ..< 8 { engine.step(chunk) }    // ~768 ms of silence

        let snapshot = engine.snapshot()
        XCTAssertEqual(snapshot.confirmed.count, 1)
        XCTAssertEqual(snapshot.confirmed[0].text, "batch 0")
        XCTAssertEqual(live.finishes, 1, "the closed epoch is flushed once")
        XCTAssertEqual(live.epochs, 1, "silence must not open the next epoch")

        speaking = true
        for _ in 0 ..< 3 { engine.step(chunk) }

        XCTAssertEqual(live.epochs, 2, "resumed speech gets a fresh epoch")
    }

    /// THE cap invariant: a forced cut corrects the segment but must not restart
    /// the live lane — the speaker is mid-sentence and its context is still good.
    func test_forced_cap_corrects_without_restarting_the_live_lane() {
        let live = FakeLiveLane()
        let engine = makeEngine(live: live, speech: { _ in true }, maxEpochSeconds: 1)

        for _ in 0 ..< 20 { engine.step(chunk) }   // ~1.9 s of unbroken speech

        XCTAssertGreaterThanOrEqual(engine.snapshot().confirmed.count, 1)
        XCTAssertEqual(live.epochs, 1, "a forced cut must not open a new epoch")
        XCTAssertEqual(live.finishes, 0, "a forced cut must not flush the live lane")
        XCTAssertEqual(live.fedSamples, 20 * chunk.count, "audio was dropped across the cap")
    }

    /// No audio may be handed to two batch passes: overlapping ranges mean
    /// Parakeet transcribes the same words twice, and both copies reach the screen.
    func test_batch_ranges_never_overlap_across_a_forced_cap() {
        let live = FakeLiveLane()
        var ranges: [Range<Int>] = []
        let engine = makeEngine(
            live: live,
            speech: { _ in true },
            batch: { range, _ in ranges.append(range); return "ok" },
            maxEpochSeconds: 1
        )

        for _ in 0 ..< 40 { engine.step(chunk) }   // several caps
        engine.finish()

        XCTAssertGreaterThanOrEqual(ranges.count, 2, "the cap fired less than twice")
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                next.lowerBound, previous.upperBound,
                "\(previous.upperBound - next.lowerBound) samples decoded twice"
            )
        }
    }

    /// Silence after a *forced* cut is the case that can grow without bound: the
    /// cut's resumption rule holds the audio from the cut, so if the speaker walks
    /// away at the cap the buffer must still be released once the pause is real.
    func test_silence_after_a_forced_cap_does_not_accumulate_audio() {
        let live = FakeLiveLane()
        var speaking = true
        let engine = makeEngine(live: live, speech: { _ in speaking }, maxEpochSeconds: 1)

        for _ in 0 ..< 12 { engine.step(chunk) }   // trips the cap
        speaking = false
        for _ in 0 ..< 200 { engine.step(chunk) }  // ~19 s of silence after it

        XCTAssertLessThanOrEqual(
            engine.bufferedSamples, 16_000,
            "the buffer grew through the pause after a cap"
        )
    }

    /// And the phrase that eventually follows must not carry the whole pause into
    /// its batch range.
    func test_phrase_after_a_capped_pause_covers_only_the_new_speech() {
        let live = FakeLiveLane()
        var speaking = true
        var ranges: [Range<Int>] = []
        let engine = makeEngine(
            live: live,
            speech: { _ in speaking },
            batch: { range, _ in ranges.append(range); return "ok" },
            maxEpochSeconds: 1
        )

        for _ in 0 ..< 12 { engine.step(chunk) }   // trips the cap
        let afterCap = ranges.count
        speaking = false
        for _ in 0 ..< 100 { engine.step(chunk) }  // ~9.6 s pause
        speaking = true
        for _ in 0 ..< 10 { engine.step(chunk) }
        speaking = false
        for _ in 0 ..< 8 { engine.step(chunk) }    // close it

        guard ranges.count > afterCap else { return XCTFail("the new phrase never closed") }
        let phrase = ranges[afterCap]
        XCTAssertLessThan(Double(phrase.count) / 16_000.0, 3.0,
                          "the phrase dragged the pause in behind it")
    }

    /// Live text keeps flowing across a forced cap — the only user-visible cost
    /// of the cap is the batch pass, not a gap in the draft.
    func test_live_draft_continues_across_a_forced_cap() {
        let live = FakeLiveLane()
        let engine = makeEngine(live: live, speech: { _ in true }, maxEpochSeconds: 1)

        for _ in 0 ..< 12 { engine.step(chunk) }
        let mid = engine.snapshot()
        for _ in 0 ..< 6 { engine.step(chunk) }
        let after = engine.snapshot()

        XCTAssertFalse(after.provisional.isEmpty, "the draft resumes after the cap")
        XCTAssertNotEqual(after.provisional, mid.provisional)
    }

    /// A forced cap keeps the live epoch, so its text keeps growing over speech
    /// that is already confirmed. The draft must show only the part after the cut —
    /// otherwise the overlay renders the same sentence twice, once corrected and
    /// once as a draft.
    func test_forced_cap_does_not_render_confirmed_speech_twice() {
        let live = FakeLiveLane()
        let engine = makeEngine(live: live, speech: { _ in true }, maxEpochSeconds: 1)

        for _ in 0 ..< 12 { engine.step(chunk) }   // trips the cap
        let atCut = live.text
        XCTAssertFalse(atCut.isEmpty, "the epoch had text at the cut")

        for _ in 0 ..< 4 { engine.step(chunk) }
        let snapshot = engine.snapshot()

        XCTAssertFalse(
            snapshot.provisional.contains(atCut),
            "the draft still carries the confirmed phrase: \(snapshot.provisional)"
        )
        XCTAssertFalse(snapshot.provisional.isEmpty, "the draft resumed after the cap")
    }

    /// The mic flushes a partial chunk on stop, so the last frame is short. Those
    /// samples must still reach the batch pass rather than being cut at the last
    /// whole 512-sample frame.
    func test_finish_includes_a_sub_frame_tail() {
        let live = FakeLiveLane()
        var ranges: [Range<Int>] = []
        let engine = makeEngine(
            live: live,
            speech: { _ in true },
            batch: { range, _ in ranges.append(range); return "ok" }
        )

        engine.step(chunk)                                   // 1_536 = 3 whole frames
        engine.step([Float](repeating: 0, count: 300))       // short tail
        engine.finish()

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].upperBound, 1_836, "the sub-frame tail was dropped")
    }

    /// Silence after a phrase must not open an epoch. Otherwise a speaker's pause
    /// feeds a live model that has nothing to say, and the audio behind it is never
    /// released — the two things that decide whether an hour-long talk survives.
    func test_silence_after_a_phrase_opens_no_epoch() {
        let live = FakeLiveLane()
        var speaking = true
        let engine = makeEngine(live: live, speech: { _ in speaking })

        for _ in 0 ..< 10 { engine.step(chunk) }
        speaking = false
        for _ in 0 ..< 8 { engine.step(chunk) }    // endpoint closes the phrase
        let epochsAfterEndpoint = live.epochs
        let chunksAfterEndpoint = live.chunks.count

        for _ in 0 ..< 50 { engine.step(chunk) }   // ~5 s more silence

        XCTAssertEqual(live.epochs, epochsAfterEndpoint, "silence opened a live epoch")
        XCTAssertEqual(live.chunks.count, chunksAfterEndpoint, "silence was fed to the live lane")
    }

    /// Silence must not accumulate audio either: with nothing open, the buffer
    /// holds only the pre-roll the next phrase can need.
    func test_silence_does_not_accumulate_audio() {
        let live = FakeLiveLane()
        var speaking = true
        let engine = makeEngine(live: live, speech: { _ in speaking })

        for _ in 0 ..< 10 { engine.step(chunk) }
        speaking = false
        for _ in 0 ..< 100 { engine.step(chunk) }  // ~9.6 s of silence

        XCTAssertLessThanOrEqual(
            engine.bufferedSamples, 16_000,
            "the audio buffer grew through silence"
        )
    }

    /// Stopping captions finalizes the open phrase exactly once.
    func test_finish_closes_the_open_phrase_once() {
        let live = FakeLiveLane()
        let engine = makeEngine(live: live, speech: { _ in true })

        for _ in 0 ..< 5 { engine.step(chunk) }
        engine.finish()
        engine.finish()

        XCTAssertEqual(engine.snapshot().confirmed.count, 1)
        XCTAssertEqual(live.finishes, 1)
    }

    /// A pause below the endpoint is not a phrase boundary.
    func test_short_pause_does_not_confirm() {
        let live = FakeLiveLane()
        var speaking = true
        let engine = makeEngine(live: live, speech: { _ in speaking })

        for _ in 0 ..< 5 { engine.step(chunk) }
        speaking = false
        for _ in 0 ..< 2 { engine.step(chunk) }   // ~192 ms

        XCTAssertTrue(engine.snapshot().confirmed.isEmpty)
        XCTAssertEqual(live.epochs, 1)
    }

    /// The batch pass sees the phrase audio itself, sized to its range.
    func test_batch_receives_the_phrase_audio() {
        let live = FakeLiveLane()
        var speaking = true
        var calls: [(Range<Int>, Int)] = []
        let engine = makeEngine(
            live: live,
            speech: { _ in speaking },
            batch: { range, samples in calls.append((range, samples.count)); return "ok" }
        )

        for _ in 0 ..< 10 { engine.step(chunk) }
        speaking = false
        for _ in 0 ..< 8 { engine.step(chunk) }

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0.lowerBound, 0)
        XCTAssertEqual(calls[0].1, calls[0].0.count, "batch audio must match its range")
    }

    /// Regression: after a forced cap the NEXT phrase must still be corrected.
    /// The reopen is backdated by the pre-roll, so discarding to the cut would
    /// leave it unbacked and skip the batch pass silently.
    func test_phrase_after_a_forced_cap_is_still_corrected() {
        let live = FakeLiveLane()
        var speaking = true
        var batches = 0
        let engine = makeEngine(
            live: live,
            speech: { _ in speaking },
            batch: { _, _ in batches += 1; return "corrected \(batches)" },
            maxEpochSeconds: 1
        )

        for _ in 0 ..< 12 { engine.step(chunk) }   // trips the cap
        XCTAssertEqual(batches, 1)

        for _ in 0 ..< 12 { engine.step(chunk) }   // keep speaking
        speaking = false
        for _ in 0 ..< 8 { engine.step(chunk) }    // real endpoint

        XCTAssertGreaterThanOrEqual(batches, 2, "the post-cap phrase was never corrected")
        XCTAssertTrue(
            engine.snapshot().confirmed.allSatisfy { $0.text.hasPrefix("corrected") },
            "a phrase kept its draft instead of the batch text"
        )
    }
}
