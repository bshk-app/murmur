import Foundation
import MLX
import MLXAudioSTT

// Two-tier streaming ASR. A fast monotonic lane (Nemotron at minimal latency) emits
// instant *partial* text; an accurate lane (Voxtral native streaming, 480 ms delay)
// emits *confirmed* text that overwrites the partials cross-model. Result: Nemotron's
// latency with Voxtral's accuracy — the DeepGram interim→final UX, WITHOUT the
// streaming-LA penalty.
//
// Why not Local Agreement over Voxtral? Measured: Voxtral's *native* streaming is more
// accurate (EN 2.24 % vs LA 4.48 %; on noised RU LA hallucinates/drops/switches
// language), because Voxtral is streaming-trained and re-decoding short windows throws
// that away. So the accurate lane is native streaming; the "revision" UX comes from the
// fast→accurate cross-model replacement, not from self-agreement.
//
// Merge: both lanes transcribe the same audio in order, and Voxtral lags, so its text
// is the accurate prefix while Nemotron's words beyond Voxtral's reach are the volatile
// tail. The junction is count-based; transient glitches there self-heal as Voxtral
// advances. (Upgrade path: align by [STREAMING_WORD] word-times once Nemotron exposes
// token timestamps.)

public final class TwoTierSession {
    // Fast lane as closures so it can be either MLX or CoreML/ANE Nemotron (the latter
    // is #if-gated and a different type) without coupling this class to either.
    private let fastStep: ([Float]) -> Void
    private let fastText: () -> String
    private let fastFinish: () -> Void
    private let accurate: VoxtralRealtimeStreamSession  // accurate finals, lags

    // Overload guard. The fast lane consumes every chunk regardless, so when the
    // pipeline falls behind we can *finish* the accurate lane rather than starve
    // it: its stream ends cleanly at the hand-off and the fast lane, which has
    // full context, carries the rest. Skipping chunks instead would tear a hole
    // in Voxtral's context and lose words from the transcript that gets pasted.
    private var valve: OverloadValve?
    private var accurateClosed = false

    /// True once the accurate lane was dropped mid-utterance. Callers should say
    /// so rather than let quality change silently.
    public private(set) var didShedAccurateLane = false

    /// Designated init: caller supplies the fast lane (MLX or ANE Nemotron) as closures.
    /// `voxtralDelayMs` trades latency for accuracy on the accurate lane — and because
    /// the fast lane hides that latency, a larger delay (e.g. 960 ms) buys near-offline
    /// finals "for free". nil = the model's default (480 ms).
    /// `valve` nil disables the overload guard — offline benchmarking wants raw
    /// throughput, because a run that sheds mid-clip no longer measures what the
    /// hardware can do.
    public init(fastStep: @escaping ([Float]) -> Void, fastText: @escaping () -> String,
                fastFinish: @escaping () -> Void, voxtral: VoxtralRealtimeModel,
                voxtralDelayMs: Int? = 960,     // 960ms = accuracy sweet spot; partials hide it
                valve: OverloadValve? = OverloadValve()) {
        self.fastStep = fastStep
        self.fastText = fastText
        self.fastFinish = fastFinish
        self.accurate = voxtral.makeStreamSession(transcriptionDelayMs: voxtralDelayMs)
        self.valve = valve
    }

    /// Convenience: MLX Nemotron fast lane.
    public convenience init(nemotron: NemotronASRModel, voxtral: VoxtralRealtimeModel,
                            language: String? = nil, fastChunkMs: Int = TwoTierEngine.defaultFastChunkMs,
                            voxtralDelayMs: Int? = 960,
                            valve: OverloadValve? = OverloadValve()) {
        let f = nemotron.makeStreamSession(language: language, chunkMs: fastChunkMs)
        self.init(fastStep: { _ = f.step($0) }, fastText: { f.text }, fastFinish: { _ = f.finish() },
                  voxtral: voxtral, voxtralDelayMs: voxtralDelayMs, valve: valve)
    }

    /// Accurate (Voxtral) text covered so far — not revised once Voxtral commits it.
    public var confirmed: String { accurate.text }

    /// Instant (Nemotron) tail beyond Voxtral's coverage — provisional, to be replaced.
    public var partial: String {
        let conf = Self.words(accurate.text)
        let fastW = Self.words(fastText())
        return fastW.count > conf.count ? fastW[conf.count...].joined(separator: " ") : ""
    }

    /// Full live view: confirmed prefix + provisional tail.
    public var text: String { let p = partial; return p.isEmpty ? confirmed : confirmed + " " + p }

    /// Ingest 16 kHz mono samples into both lanes; returns the current split.
    private let debug = ProcessInfo.processInfo.environment["TWOTIER_DEBUG"] != nil
    private var steps = 0

    @discardableResult
    public func step(_ samples: [Float]) -> (confirmed: String, partial: String) {
        let audioSeconds = Double(samples.count) / 16000.0
        let t0 = ProcessInfo.processInfo.systemUptime

        fastStep(samples)                       // always — it must keep full context
        if !accurateClosed {
            if valve?.isShedding == true {
                _ = accurate.finish()           // end the stream cleanly; its text freezes here
                accurateClosed = true
                didShedAccurateLane = true
            } else {
                _ = accurate.step(samples)
            }
        }
        valve?.record(compute: ProcessInfo.processInfo.systemUptime - t0, audio: audioSeconds)

        let (c, p) = (confirmed, partial)
        if debug { steps += 1; if steps % 12 == 0 {
            FileHandle.standardError.write(Data("[2TIER] conf=\(Self.words(c).count)w  partial=⟨\(p)⟩\n".utf8))
        } }
        return (c, p)
    }

    /// End of stream: flush both lanes. Voxtral is the authority — its full text is the
    /// final transcript (the partial tail is subsumed once Voxtral catches up).
    @discardableResult
    public func finish() -> (confirmed: String, partial: String) {
        fastFinish()
        if !accurateClosed { _ = accurate.finish(); accurateClosed = true }
        // After a shed, everything spoken past the hand-off exists ONLY in the fast
        // lane. Returning `accurate.text` alone would drop the tail — the guard
        // against waiting would cost words, which is what it exists to prevent.
        // Untouched when nothing was shed, so the normal path keeps Voxtral's
        // authority and the approximate word-count merge stays out of the final.
        return (didShedAccurateLane ? text : accurate.text, "")
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
}
