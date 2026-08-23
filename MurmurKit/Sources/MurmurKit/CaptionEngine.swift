import Foundation

/// Captions policy: a continuous live draft, corrected phrase by phrase by the
/// batch model while the talk is still going.
///
/// Model-free by construction — the live lane and the batch pass arrive as
/// closures, so the whole lifecycle (when an epoch restarts, which audio a
/// correction sees, what the overlay shows) is testable without MLX.
///
/// Two boundary kinds, deliberately different:
///   * a real pause — correct the phrase, then start a fresh live epoch, since
///     the epoch's cost grows with its length and its context is worthless once
///     the speaker has stopped;
///   * the safety cap — correct the phrase but keep the epoch, because the
///     speaker is mid-sentence and restarting there would degrade the draft.
final class CaptionEngine {
    struct LiveLane {
        let begin: () -> Void
        let step: ([Float]) -> Void
        let text: () -> String
        let finish: () -> Void
    }

    static let sampleRate = 16_000
    /// Confirmed phrases kept for the overlay; older ones are dropped so an
    /// hour-long talk stays bounded.
    static let confirmedHistory = 24

    /// Longest a phrase may run without a pause before it is corrected anyway.
    /// Measured: a 60 s Parakeet pass costs ~0.45 s, so a monologue of unbroken
    /// speech is bounded by this rather than by the speaker.
    static let defaultMaxEpochSeconds: Double = 60

    private let live: LiveLane
    private let isSpeech: ([Float]) -> Bool
    private let batch: (Range<Int>, [Float]) -> String
    private let frameSamples = 512      // Silero's 32 ms frame
    private let preRollSamples: Int

    private var policy: SpeechBoundaryPolicy
    private var transcript = CaptionTranscript()
    private var audio = CaptionAudioBuffer()
    private var frameRemainder: [Float] = []
    private var openSegment: UInt64?
    private var epochOpen = false
    /// Live text already accounted for by a confirmed phrase in this epoch — only
    /// non-empty between a forced cut and the epoch's end.
    private var confirmedPrefix = ""

    init(
        live: LiveLane,
        isSpeech: @escaping ([Float]) -> Bool,
        batch: @escaping (Range<Int>, [Float]) -> String,
        endpointSilence: Double = 0.48,
        preRoll: Double = 0.288,
        maxEpochSeconds: Double = CaptionEngine.defaultMaxEpochSeconds
    ) {
        self.live = live
        self.isSpeech = isSpeech
        self.preRollSamples = Int(preRoll * Double(Self.sampleRate))
        self.batch = batch
        let rate = Double(Self.sampleRate)
        self.policy = SpeechBoundaryPolicy(
            frameSamples: frameSamples,
            preRollSamples: Int(preRoll * rate),
            endpointSilenceFrames: max(1, Int((endpointSilence * rate) / Double(frameSamples))),
            maxEpochSamples: Int(maxEpochSeconds * rate)
        )
    }

    /// Feed one mic chunk.
    ///
    /// Work is per 512-sample frame, not per chunk: the VAD verdict for a frame
    /// decides whether that same frame reaches the live lane. Feeding the whole
    /// chunk first would hand the samples after an endpoint to the epoch that just
    /// ended, and would keep a live epoch running through silence — the two ways
    /// this loop stops being affordable over an hour.
    func step(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        audio.append(chunk)
        frameRemainder.append(contentsOf: chunk)
        while frameRemainder.count >= frameSamples {
            let frame = Array(frameRemainder.prefix(frameSamples))
            frameRemainder.removeFirst(frameSamples)
            let event = policy.frame(isSpeech: isSpeech(frame))
            if case .opened = event, !epochOpen { beginEpoch() }
            if epochOpen { live.step(frame) }
            if let event {
                apply(event)
            } else if let id = openSegment {
                transcript.updateProvisional(id, text: draftText())
            }
        }
        releaseSilentAudio()
    }

    /// Close the open phrase, once. The tail past the last whole frame is part of
    /// the phrase, so the range runs to the end of captured audio.
    func finish() {
        if let event = policy.finish(endSample: audio.endSample) { apply(event) }
        if epochOpen { live.finish(); epochOpen = false }
        frameRemainder.removeAll(keepingCapacity: false)
    }

    func snapshot() -> CaptionSnapshot { transcript.snapshot() }

    /// Samples held for the batch pass — the buffer this loop must keep bounded.
    var bufferedSamples: Int { audio.count }

    // MARK: boundaries

    /// With no phrase open, only the next phrase's pre-roll can still be needed;
    /// everything older is released so a long pause costs nothing. A forced cut
    /// never reaches back further than that (see `forcedCutPoint`), so this one
    /// rule covers both kinds of boundary.
    private func releaseSilentAudio() {
        guard openSegment == nil else { return }
        audio.discard(before: policy.consumedSamples - preRollSamples)
    }

    /// The live lane's text for the *current* phrase.
    ///
    /// After a forced cut the epoch survives, so `live.text()` still carries the
    /// speech that was just confirmed. Showing it again would render the same
    /// sentence twice — once corrected, once as a draft — so the confirmed prefix
    /// is dropped. This is a prefix cut on one model's own monotonic output, not a
    /// merge between the two lanes; if the model revised that prefix, the whole
    /// text is shown rather than a wrong slice.
    private func draftText() -> String {
        let text = live.text()
        guard !confirmedPrefix.isEmpty else { return text }
        guard text.hasPrefix(confirmedPrefix) else { return text }
        return String(text.dropFirst(confirmedPrefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private func apply(_ event: SpeechBoundaryEvent) {
        switch event {
        case let .opened(startSample):
            openSegment = transcript.open(startSample: startSample)
            transcript.updateProvisional(openSegment!, text: draftText())

        case let .closed(range, forced):
            let id = openSegment ?? transcript.open(startSample: range.lowerBound)
            openSegment = nil
            transcript.close(id, endSample: range.upperBound)
            // A real pause ends the epoch; the cap does not — see the type doc.
            if forced {
                // The epoch lives on, so remember how much of its text this phrase
                // already accounts for.
                confirmedPrefix = live.text()
            } else if epochOpen {
                live.finish()
                epochOpen = false
            }
            correct(id, range: range)
        }
    }

    /// Run the batch pass over one phrase and install its text.
    ///
    /// Everything up to the phrase's end is released here. Segments never
    /// overlap — the policy floors a reopen at the previous end — so no later
    /// phrase can want these samples back. Holding the *next* phrase's pre-roll
    /// is `releaseSilentAudio`'s job, and it has the cursor to do it exactly.
    private func correct(_ id: UInt64, range: Range<Int>) {
        guard audio.contains(range) else {
            // Not reachable with contiguous ranges; keep the draft rather than
            // blank the line, and say so instead of failing silently.
            assertionFailure("caption range \(range) is no longer buffered")
            transcript.confirm(id, text: "")
            return
        }
        transcript.confirm(id, text: batch(range, audio.slice(range)))
        transcript.trimConfirmed(keep: Self.confirmedHistory)
        audio.discard(before: range.upperBound)
    }

    /// Only ever called with no epoch running: a forced cut leaves the epoch open
    /// on purpose, and starting one there would both defeat the cap and abandon a
    /// live session without flushing it.
    private func beginEpoch() {
        live.begin()
        epochOpen = true
        confirmedPrefix = ""   // a fresh epoch's text is all new
    }
}

/// Absolute-addressed audio for the batch lane: phrases are handed over as
/// sample ranges, and everything a correction has consumed is dropped.
struct CaptionAudioBuffer {
    private var samples: [Float] = []
    private var base = 0            // absolute index of samples[0]

    var endSample: Int { base + samples.count }
    var count: Int { samples.count }

    mutating func append(_ chunk: [Float]) {
        samples.append(contentsOf: chunk)
    }

    func contains(_ range: Range<Int>) -> Bool {
        range.lowerBound >= base && range.upperBound <= endSample
    }

    func slice(_ range: Range<Int>) -> [Float] {
        guard contains(range) else { return [] }
        return Array(samples[(range.lowerBound - base) ..< (range.upperBound - base)])
    }

    mutating func discard(before sample: Int) {
        let drop = min(max(0, sample - base), samples.count)
        guard drop > 0 else { return }
        samples.removeFirst(drop)
        base += drop
    }
}
