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

    /// Designated init: caller supplies the fast lane (MLX or ANE Nemotron) as closures.
    /// `voxtralDelayMs` trades latency for accuracy on the accurate lane — and because
    /// the fast lane hides that latency, a larger delay (e.g. 960 ms) buys near-offline
    /// finals "for free". nil = the model's default (480 ms).
    public init(fastStep: @escaping ([Float]) -> Void, fastText: @escaping () -> String,
                fastFinish: @escaping () -> Void, voxtral: VoxtralRealtimeModel,
                voxtralDelayMs: Int? = 960) {   // 960ms = accuracy sweet spot; partials hide it
        self.fastStep = fastStep
        self.fastText = fastText
        self.fastFinish = fastFinish
        self.accurate = voxtral.makeStreamSession(transcriptionDelayMs: voxtralDelayMs)
    }

    /// Convenience: MLX Nemotron fast lane.
    public convenience init(nemotron: NemotronASRModel, voxtral: VoxtralRealtimeModel,
                            language: String? = nil, fastChunkMs: Int = TwoTierEngine.defaultFastChunkMs,
                            voxtralDelayMs: Int? = 960) {
        let f = nemotron.makeStreamSession(language: language, chunkMs: fastChunkMs)
        self.init(fastStep: { _ = f.step($0) }, fastText: { f.text }, fastFinish: { _ = f.finish() },
                  voxtral: voxtral, voxtralDelayMs: voxtralDelayMs)
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
        fastStep(samples)
        _ = accurate.step(samples)
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
        _ = accurate.finish()
        return (accurate.text, "")
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
}
