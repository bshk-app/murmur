import Foundation

/// Where one caption segment begins and ends, in absolute sample positions.
enum SpeechBoundaryEvent: Equatable {
    case opened(startSample: Int)
    /// `forced` marks the safety cap rather than a real pause: the speaker is
    /// still talking, so the live lane must keep running across it.
    case closed(range: Range<Int>, forced: Bool)
}

/// Segment boundaries from per-frame speech verdicts. No audio, no models — the
/// caller runs the VAD and owns the samples; this only decides where to cut.
///
/// Boundaries are *markers*: closing a segment hands a range to the batch pass,
/// it never drops audio and never implies the live lane should stop.
struct SpeechBoundaryPolicy {
    private let frameSamples: Int
    private let preRollSamples: Int
    private let endpointSilenceFrames: Int
    private let maxEpochSamples: Int

    private var cursor = 0            // samples consumed, i.e. end of last frame
    private var openStart: Int?       // start of the live segment, pre-roll applied
    private var lastSpeechEnd = 0     // end of the newest speech frame
    private var lastClosedEnd = 0     // end of the newest closed segment
    private var lastGapEnd: Int?      // end of the newest non-speech frame
    private var silentFrames = 0

    init(
        frameSamples: Int,
        preRollSamples: Int,
        endpointSilenceFrames: Int,
        maxEpochSamples: Int
    ) {
        self.frameSamples = frameSamples
        self.preRollSamples = preRollSamples
        self.endpointSilenceFrames = endpointSilenceFrames
        self.maxEpochSamples = maxEpochSamples
    }

    /// Feed one VAD verdict. Returns a boundary when this frame produced one.
    mutating func frame(isSpeech: Bool) -> SpeechBoundaryEvent? {
        let frameStart = cursor
        cursor += frameSamples

        guard openStart != nil else {
            guard isSpeech else { return nil }
            // Pre-roll catches the syllable the VAD missed, so it may only reach
            // back into silence. After a forced cut the speech either side is
            // contiguous: backdating there would hand the same samples to two
            // batch passes and have them transcribed twice.
            let start = max(frameStart - preRollSamples, lastClosedEnd)
            openStart = start
            lastSpeechEnd = cursor
            silentFrames = 0
            return .opened(startSample: start)
        }

        if isSpeech {
            lastSpeechEnd = cursor
            silentFrames = 0
            // Runaway speech: cut at the cap so the batch pass — and the live
            // epoch behind it — stay bounded.
            if let start = openStart, cursor - start >= maxEpochSamples {
                return close(at: forcedCutPoint(notBefore: start), forced: true)
            }
            return nil
        }

        lastGapEnd = cursor
        silentFrames += 1
        guard silentFrames >= endpointSilenceFrames else { return nil }
        return close(at: lastSpeechEnd, forced: false)
    }

    /// Where to cut when the cap is reached.
    ///
    /// The cap fires mid-speech, so cutting at the cursor can land inside a word —
    /// and then both batch passes reconstruct that word and it reaches the screen
    /// twice. A brief gap just before the cap is a better seam, so use the newest
    /// one in reach; fast continuous speech has none, and then the cursor still
    /// bounds the phrase. (Measured on 11 cuts of real speech: 2 found a gap.)
    ///
    /// Reach is exactly the pre-roll, and that is a constraint rather than a
    /// tuning choice: the next phrase reopens no earlier than
    /// `frameStart - preRollSamples`, so a cut further back would leave the samples
    /// between belonging to no phrase at all — dropped from the transcript with
    /// nothing reporting it. Trading a duplicated word for lost words is not a
    /// trade worth making, and a longer reach measured no better.
    private func forcedCutPoint(notBefore start: Int) -> Int {
        let earliest = max(start + frameSamples, cursor - preRollSamples)
        guard let gap = lastGapEnd, gap >= earliest, gap < cursor else { return cursor }
        return gap
    }

    /// Samples the policy has consumed — frame-aligned, so it lags the audio by
    /// up to one frame.
    var consumedSamples: Int { cursor }

    /// Close whatever is still open, e.g. when the user stops captions.
    ///
    /// `endSample` is the true end of captured audio: the mic flushes a partial
    /// chunk on stop, and those samples belong to the phrase even though they
    /// never formed a whole VAD frame.
    mutating func finish(endSample: Int? = nil) -> SpeechBoundaryEvent? {
        guard openStart != nil else { return nil }
        return close(at: max(lastSpeechEnd, endSample ?? cursor), forced: false)
    }

    private mutating func close(at end: Int, forced: Bool) -> SpeechBoundaryEvent? {
        guard let start = openStart, end > start else {
            openStart = nil
            silentFrames = 0
            return nil
        }
        openStart = nil
        silentFrames = 0
        lastClosedEnd = end
        lastGapEnd = nil
        return .closed(range: start ..< end, forced: forced)
    }
}
