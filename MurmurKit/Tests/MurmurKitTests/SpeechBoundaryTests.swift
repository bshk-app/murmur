import XCTest
@testable import MurmurKit

/// The boundary policy is pure: it takes per-frame speech verdicts and the
/// running sample cursor, and says where a caption segment starts and ends.
final class SpeechBoundaryTests: XCTestCase {
    private let frame = 512          // 32 ms @ 16 kHz
    private let silenceFrames = 15   // 480 ms
    private let capSamples = 16_000 * 60
    private let preRollSamples = 4_608   // 288 ms

    private func makePolicy() -> SpeechBoundaryPolicy {
        SpeechBoundaryPolicy(
            frameSamples: frame,
            preRollSamples: preRollSamples,
            endpointSilenceFrames: silenceFrames,
            maxEpochSamples: capSamples
        )
    }

    /// Leading silence is not a segment: nothing opens until speech is seen.
    func test_silence_alone_opens_no_segment() {
        var policy = makePolicy()
        for _ in 0 ..< 40 {
            XCTAssertNil(policy.frame(isSpeech: false))
        }
    }

    /// The first speech frame opens a segment, backdated by the pre-roll so the
    /// batch pass never starts mid-word.
    func test_speech_opens_a_segment_with_pre_roll() {
        var policy = makePolicy()
        for _ in 0 ..< 20 { _ = policy.frame(isSpeech: false) }   // 10_240 samples in

        let event = policy.frame(isSpeech: true)

        XCTAssertEqual(event, .opened(startSample: 10_240 - 4_608))
    }

    /// A pause shorter than the endpoint keeps the segment open.
    func test_short_pause_does_not_close_the_segment() {
        var policy = makePolicy()
        _ = policy.frame(isSpeech: true)

        for _ in 0 ..< (silenceFrames - 1) {
            XCTAssertNil(policy.frame(isSpeech: false))
        }
    }

    /// 480 ms of silence closes exactly one segment, ending at the last speech.
    func test_endpoint_silence_closes_one_segment() {
        var policy = makePolicy()
        _ = policy.frame(isSpeech: true)                     // opens at 0
        for _ in 0 ..< 9 { _ = policy.frame(isSpeech: true) } // speech through 5_120

        var closed: [SpeechBoundaryEvent] = []
        for _ in 0 ..< (silenceFrames + 5) {
            if let event = policy.frame(isSpeech: false) { closed.append(event) }
        }

        XCTAssertEqual(closed, [.closed(range: 0 ..< 5_120, forced: false)])
    }

    /// Continuous speech never reaches the endpoint, so the cap is what bounds
    /// the epoch. It is marked `forced`: the speaker has not stopped.
    func test_uninterrupted_speech_is_cut_at_the_cap() {
        var policy = makePolicy()
        var events: [SpeechBoundaryEvent] = []
        for _ in 0 ..< (capSamples / frame + 10) {
            if let event = policy.frame(isSpeech: true) { events.append(event) }
        }

        XCTAssertEqual(events.first, .opened(startSample: 0))
        let forced = events.dropFirst().first
        guard case let .closed(range, isForced)? = forced else {
            return XCTFail("expected a forced close, got \(String(describing: forced))")
        }
        XCTAssertTrue(isForced)
        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertGreaterThanOrEqual(range.count, capSamples)
    }

    /// Forced cuts atomically continue at the cut point. Consecutive ranges in
    /// uninterrupted speech therefore meet exactly — no duplicate and no hole.
    func test_segments_are_adjacent_across_forced_cuts() {
        var policy = makePolicy()
        var closes: [Range<Int>] = []
        for _ in 0 ..< (capSamples / frame * 2 + 20) {
            if case let .closed(range, _)? = policy.frame(isSpeech: true) {
                closes.append(range)
            }
        }

        XCTAssertGreaterThanOrEqual(closes.count, 2, "the cap fired less than twice")
        for (previous, next) in zip(closes, closes.dropFirst()) {
            XCTAssertEqual(
                next.lowerBound,
                previous.upperBound,
                "batch ranges are not adjacent: \(previous) then \(next)"
            )
        }
    }

    /// Drives the cap with a one-frame dip `dipFramesBack` frames before it, then
    /// closes the atomic continuation after one more speech frame. Its lower bound
    /// is where the next batch phrase started.
    private func capWithDip(dipFramesBack: Int) -> (closed: Range<Int>, continuation: Int) {
        var policy = makePolicy()
        var closed: Range<Int>?
        var consumed = 0
        let capFrames = capSamples / frame
        let dipAt = capFrames - dipFramesBack
        for frameIndex in 0 ..< (capFrames + 2) {
            let event = policy.frame(isSpeech: frameIndex != dipAt)
            consumed += frame
            if case let .closed(range, forced)? = event {
                XCTAssertTrue(forced, "a one-frame dip is not an endpoint")
                closed = range
                break
            }
        }
        guard let closed else { return (0 ..< 0, -1) }
        _ = policy.frame(isSpeech: true)
        consumed += frame
        guard case let .closed(continuation, _)? = policy.finish(endSample: consumed) else {
            return (closed, -1)
        }
        return (closed, continuation.lowerBound)
    }

    /// The cap cuts while the speaker is talking, so it can land inside a word —
    /// and then both batch passes reconstruct that word, printing it twice. When a
    /// gap sits within reach, cut there instead: at the gap's far edge, so the
    /// closing phrase keeps the silence and the next one starts on speech.
    func test_forced_cut_prefers_a_recent_gap() {
        let dipFramesBack = 5
        let (closed, continuation) = capWithDip(dipFramesBack: dipFramesBack)

        XCTAssertEqual(closed.upperBound, (capSamples / frame - dipFramesBack + 1) * frame,
                       "the cut ignored the gap and landed mid-word")
        XCTAssertEqual(continuation, closed.upperBound, "audio fell between the two phrases")
    }

    /// If a forced cut moves back to a recent gap, the samples between that gap
    /// and the current cursor are already captured. Stopping before another frame
    /// must still hand that reserved tail to the batch pass.
    func test_finish_immediately_after_a_gap_cut_closes_the_reserved_tail() {
        var policy = makePolicy()
        let capFrames = capSamples / frame
        let dipAt = capFrames - 5
        var closed: Range<Int>?
        var consumed = 0
        for frameIndex in 0 ..< (capFrames + 2) {
            let event = policy.frame(isSpeech: frameIndex != dipAt)
            consumed += frame
            if case let .closed(range, forced)? = event {
                XCTAssertTrue(forced)
                closed = range
                break
            }
        }
        guard let closed else { return XCTFail("the cap never fired") }

        XCTAssertEqual(
            policy.finish(endSample: consumed),
            .closed(range: closed.upperBound ..< consumed, forced: false)
        )
    }

    /// A gap further back than the pre-roll must be ignored: the reopen cannot
    /// follow the cut that far, so moving there would drop the audio between —
    /// losing words to save a duplicated one.
    func test_forced_cut_ignores_a_gap_beyond_the_pre_roll() {
        let dipFramesBack = preRollSamples / frame + 12    // well outside reach
        let (closed, continuation) = capWithDip(dipFramesBack: dipFramesBack)

        XCTAssertGreaterThan(closed.upperBound, (capSamples / frame - dipFramesBack) * frame,
                             "the cut moved further back than the continuation can follow")
        XCTAssertEqual(continuation, closed.upperBound, "audio fell between the two phrases")
    }

    /// With no gap to use — unbroken phonation — the cap still bounds the phrase,
    /// and the next phrase still starts exactly where this one ended.
    func test_forced_cut_falls_back_to_the_cap_without_a_gap() {
        var policy = makePolicy()
        var closed: Range<Int>?
        var consumed = 0
        for _ in 0 ..< (capSamples / frame + 6) {
            let event = policy.frame(isSpeech: true)
            consumed += frame
            if case let .closed(range, _)? = event {
                closed = range
                break
            }
        }
        guard let closed else { return XCTFail("the cap never fired") }
        _ = policy.frame(isSpeech: true)
        consumed += frame
        guard case let .closed(continuation, _)? = policy.finish(endSample: consumed) else {
            return XCTFail("the continuation never closed")
        }

        XCTAssertGreaterThanOrEqual(closed.count, capSamples)
        XCTAssertEqual(continuation.lowerBound, closed.upperBound, "audio fell between the phrases")
    }

    /// A pause *after* the cap is still a pause. The forced-cut rule — resume
    /// exactly where we cut — only holds while the speech is contiguous; once the
    /// endpoint's worth of silence has passed, the next phrase must start near the
    /// speech, not drag the whole pause in behind it.
    func test_pause_after_a_forced_cut_resumes_with_pre_roll() {
        var policy = makePolicy()
        var closed: Range<Int>?
        var consumed = 0
        // Speak until the cap fires, and stop there: another speech frame would
        // open the next phrase and the pause would no longer follow the cut.
        for _ in 0 ..< (capSamples / frame + 6) {
            let event = policy.frame(isSpeech: true)
            consumed += frame
            if case let .closed(range, forced)? = event {
                XCTAssertTrue(forced)
                closed = range
                break
            }
        }
        guard let closed else { return XCTFail("the cap never fired") }

        // The speaker stops right after the cap, for far longer than an endpoint.
        // With a cursor cut there is no reserved tail to emit; with a gap cut the
        // tail closes here. Either way, the next speech must use normal pre-roll.
        for _ in 0 ..< (silenceFrames + 200) {
            _ = policy.frame(isSpeech: false)
            consumed += frame
        }

        guard case let .opened(start)? = policy.frame(isSpeech: true) else {
            return XCTFail("speech after the pause opened nothing")
        }
        XCTAssertEqual(start, consumed - preRollSamples,
                       start == closed.upperBound
                           ? "the phrase swallowed the whole pause"
                           : "the phrase started at the wrong place")
    }

    /// After a real pause the pre-roll lands in silence, which is the case it was
    /// added for — so it must still apply there in full.
    func test_pre_roll_still_applies_after_real_silence() {
        var policy = makePolicy()
        _ = policy.frame(isSpeech: true)
        var closed: Range<Int>?
        var consumed = frame
        for _ in 0 ..< (silenceFrames + 4) {
            if case let .closed(range, _)? = policy.frame(isSpeech: false) { closed = range }
            consumed += frame
        }
        guard let closed else { return XCTFail("the endpoint never closed the phrase") }

        guard case let .opened(start)? = policy.frame(isSpeech: true) else {
            return XCTFail("speech after the pause opened nothing")
        }
        XCTAssertEqual(start, consumed - preRollSamples, "pre-roll was not applied after a real pause")
        XCTAssertGreaterThanOrEqual(start, closed.upperBound, "pre-roll reached into the closed phrase")
    }

    /// Stopping captions mid-phrase still hands the batch pass its range, once.
    func test_finish_closes_an_open_segment_once() {
        var policy = makePolicy()
        _ = policy.frame(isSpeech: true)
        _ = policy.frame(isSpeech: true)

        XCTAssertEqual(policy.finish(), .closed(range: 0 ..< 1_024, forced: false))
        XCTAssertNil(policy.finish())
    }


    /// Warm-up must execute one correctly sized zero frame and then clear the
    /// streaming state, so the first live verdict starts from a clean detector.
    func test_detector_warmup_runs_one_silent_frame_then_resets() {
        var fed: [Float]?
        var resets = 0

        SpeechBoundaryDetector.performWarmUp(
            frameSamples: SpeechBoundaryDetector.frameSamples,
            feed: { fed = $0 },
            reset: { resets += 1 }
        )

        XCTAssertEqual(fed, [Float](repeating: 0, count: SpeechBoundaryDetector.frameSamples))
        XCTAssertEqual(resets, 1)
    }
    /// Silence after a closed segment must not open an empty one.

    func test_finish_after_endpoint_yields_nothing() {
        var policy = makePolicy()
        _ = policy.frame(isSpeech: true)
        for _ in 0 ..< (silenceFrames + 2) { _ = policy.frame(isSpeech: false) }

        XCTAssertNil(policy.finish())
    }
}
