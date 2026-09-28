import Foundation

/// Where one caption segment begins and ends, in absolute sample positions.
public enum SpeechBoundaryEvent: Equatable {
    case opened(startSample: Int)
    /// `forced` marks the safety cap rather than a real pause: the continuation
    /// starts at this range's upper bound with no audio gap or overlap.
    case closed(range: Range<Int>, forced: Bool)
}

/// Segment boundaries from per-frame speech verdicts. No audio, no models — the
/// caller runs the VAD and owns the samples; this only decides where to cut.
///
/// Boundaries are markers: closing a segment hands a range to the batch pass.
/// A forced close atomically opens its continuation at the same sample.
public struct SpeechBoundaryPolicy {
    /// A phrase shorter than `sentenceSeconds` ends only at a pause this long;
    /// tuned on speakers who stop to think in the middle of a sentence.
    public static let hesitationSeconds = 1.5
    public static let sentenceSeconds = 4.0

    private let frameSamples: Int
    private let preRollSamples: Int
    private let endpointSilenceFrames: Int
    private let maxEpochSamples: Int
    private let hardMaximumSamples: Int?
    private let minimumPhraseSamples: Int
    private let hesitationFrames: Int

    private var cursor = 0            // samples consumed, i.e. end of last frame
    private var openStart: Int?       // start of the live segment, pre-roll applied
    private var lastSpeechEnd = 0     // end of the newest speech frame
    private var lastClosedEnd = 0     // end of the newest closed segment
    private var lastGapEnd: Int?      // end of the newest non-speech frame
    /// Cursor-aligned cap waiting to learn whether Stop flushes a sub-frame tail.
    private var pendingCursorCut: Int?
    private var silentFrames = 0

    public init(
        frameSamples: Int,
        preRollSamples: Int,
        endpointSilenceFrames: Int,
        maxEpochSamples: Int,
        hardMaximumSamples: Int? = nil,
        minimumPhraseSamples: Int = 0,
        hesitationFrames: Int? = nil
    ) {
        self.frameSamples = frameSamples
        self.preRollSamples = preRollSamples
        self.endpointSilenceFrames = endpointSilenceFrames
        self.maxEpochSamples = maxEpochSamples
        self.hardMaximumSamples = hardMaximumSamples
        self.minimumPhraseSamples = minimumPhraseSamples
        self.hesitationFrames = hesitationFrames ?? endpointSilenceFrames
    }

    /// Feed one VAD verdict. Returns a boundary when this frame produced one.
    public mutating func frame(isSpeech: Bool) -> SpeechBoundaryEvent? {
        let frameStart = cursor
        cursor += frameSamples
        guard openStart != nil else {
            guard isSpeech else {
                // A complete silent frame proves there is no speech tail after a
                // cursor cap; only a sub-frame Stop/EOF tail needs preservation.
                pendingCursorCut = nil
                return nil
            }
            pendingCursorCut = nil
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

        // Batch models have a strict input limit, including trailing silence.
        // The regular speech cap below alone cannot bound an EOF following one
        // or two silent frames. Preserve the remainder as a continuation.
        if let limit = hardMaximumSamples, let start = openStart, cursor - start >= limit {
            if isSpeech { lastSpeechEnd = cursor }
            return close(at: start + limit, forced: true)
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
        guard silentFrames >= requiredSilenceFrames else { return nil }
        return close(at: lastSpeechEnd, forced: false)
    }

    /// A speaker who hesitates mid-sentence has not finished it. Until a phrase
    /// reaches the minimum length only a hesitation-long pause ends it, so the
    /// batch pass hears the sentence whole rather than one fragment per breath.
    private var requiredSilenceFrames: Int {
        guard let start = openStart, lastSpeechEnd - start < minimumPhraseSamples else { return endpointSilenceFrames }
        return hesitationFrames
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
    public var consumedSamples: Int { cursor }

    /// Earliest sample the open or the next phrase can start at: pre-roll never
    /// reaches into a closed phrase, and a new one opens one pre-roll back at most.
    public var nextPhraseStart: Int { openStart ?? max(cursor - preRollSamples, lastClosedEnd) }

    /// Close whatever is still open, e.g. when the user stops captions.
    ///
    /// `endSample` is the true end of captured audio: the mic flushes a partial
    /// chunk on stop, and those samples belong to the phrase even though they
    /// never formed a whole VAD frame.
    public mutating func finish(endSample: Int? = nil) -> SpeechBoundaryEvent? {
        if openStart != nil {
            return close(at: max(lastSpeechEnd, endSample ?? cursor), forced: false)
        }
        guard let start = pendingCursorCut else { return nil }
        pendingCursorCut = nil
        let end = endSample ?? cursor
        guard end > start else { return nil }
        lastClosedEnd = end
        return .closed(range: start ..< end, forced: false)
    }

    private mutating func close(at end: Int, forced: Bool) -> SpeechBoundaryEvent? {
        guard let start = openStart, end > start else {
            openStart = nil
            silentFrames = 0
            return nil
        }
        // A gap-based forced cut reserves captured audio between the gap and the
        // cursor, so its continuation is open immediately. A cursor-aligned cut
        // reserves nothing; wait for the next speech frame instead, or silence
        // would leave an empty continuation that cannot close.
        openStart = forced && end < cursor ? end : nil
        pendingCursorCut = forced && end == cursor ? end : nil
        silentFrames = 0
        lastClosedEnd = end
        lastGapEnd = nil
        return .closed(range: start ..< end, forced: forced)
    }
}
