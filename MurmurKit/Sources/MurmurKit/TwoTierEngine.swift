import Foundation
import MLX
import MLXAudioSTT

/// Murmur's two-tier composition policy. Caps Metal memory and loads the fast
/// (Nemotron) and/or accurate (Voxtral) models **lazily, per mode**: `prepare(.fast)`
/// never drags in the 4 B Voxtral, `prepare(.accurate)` never loads Nemotron, and
/// switching modes loads only the missing model. It then vends a fresh session per
/// utterance (a session accumulates text, so each dictation needs a clean one).
///
/// This is **application** policy — which two models, how to merge them, the memory
/// budget — not a library primitive, so it lives in MurmurKit, built on the
/// library's public streaming primitives (`fromPretrained` / `makeStreamSession`).
public final class TwoTierEngine {
    public static let defaultNemotronRepo = "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
    public static let defaultVoxtralRepo = "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"

    /// Fast-lane (Nemotron) chunk in ms — SSOT for both the hybrid fast lane and
    /// the fast-only mode. The cost is partial latency, which the accurate lane's
    /// 960 ms delay hides; that head start is the ceiling on this value, because a
    /// fast lane that arrives no sooner than the accurate one has no purpose.
    ///
    /// **Measure this, do not reason about it.** Hybrid RTF on a base M1, min of
    /// three warm passes: 160 → 2.41, 240 → 3.06, **320 → 2.29**, 480 → 4.59,
    /// 640 → 3.57. No arithmetic fits — a doubling rule was tested at 640 and
    /// refuted. The likely cause is Metal kernel specialisation per tensor shape,
    /// so neighbouring values can differ by 2×. 320 is an empirical point.
    ///
    /// Earlier bench, kept for history: 160 beat 80 on both RTF (−40 %) and WER
    /// (10.6 % vs 14.9 %) with `[56,1]`, 1-chunk lookahead.
    public static let defaultFastChunkMs = 320

    private let nemotronRepo: String
    private let voxtralRepo: String
    private var nemotron: NemotronASRModel?
    private var voxtral: VoxtralRealtimeModel?

    /// MLX's cache ceiling, scaled to the machine.
    ///
    /// It used to be a flat 18 GB, which is above physical memory on every base
    /// Apple Silicon Mac — a cap above RAM is not a cap, it is permission to grow
    /// into swap.
    public static var defaultMemoryLimitBytes: Int {
        Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.6)
    }

    /// Caps Metal memory up front (an unbounded MLX run can OOM-reboot the Mac);
    /// models load lazily via `prepare`.
    public init(
        nemotronRepo: String = defaultNemotronRepo,
        voxtralRepo: String = defaultVoxtralRepo,
        memoryLimitBytes: Int = TwoTierEngine.defaultMemoryLimitBytes
    ) {
        GPU.set(memoryLimit: memoryLimitBytes, relaxed: false)
        self.nemotronRepo = nemotronRepo
        self.voxtralRepo = voxtralRepo
    }

    /// Download (first run) + load ONLY the models `mode` needs. Memoized — a model
    /// already loaded is reused, so a mode switch loads just what's missing.
    public func prepare(_ mode: DictationMode) async throws {
        switch mode {
        case .fast:     _ = try await loadNemotron()
        case .accurate: _ = try await loadVoxtral()
        case .hybrid:   _ = try await loadNemotron(); _ = try await loadVoxtral()
        }
    }

    /// Whether the models `mode` needs are loaded (so a session can be made).
    public func isReady(_ mode: DictationMode) -> Bool {
        switch mode {
        case .fast:     return nemotron != nil
        case .accurate: return voxtral != nil
        case .hybrid:   return nemotron != nil && voxtral != nil
        }
    }

    private func loadNemotron() async throws -> NemotronASRModel {
        if let nemotron { return nemotron }
        let m = try await NemotronASRModel.fromPretrained(nemotronRepo)
        nemotron = m
        return m
    }

    private func loadVoxtral() async throws -> VoxtralRealtimeModel {
        if let voxtral { return voxtral }
        let m = try await VoxtralRealtimeModel.fromPretrained(voxtralRepo)
        voxtral = m
        return m
    }

    /// The session for `mode`, or nil if its models aren't loaded yet (call
    /// `prepare(mode)` first). Single dispatch point — STTEngine uses it for both
    /// the warm-up pass and live dictation.
    func makeSession(for mode: DictationMode, language: String? = nil,
                     valve: OverloadValve? = OverloadValve()) -> UtteranceSession? {
        switch mode {
        case .hybrid:   return makeHybridSession(language: language, valve: valve)
        case .fast:     return makeFastSession(language: language)
        case .accurate: return makeAccurateSession()
        }
    }

    /// Hybrid: `confirmed` = Voxtral finals, `partial` = Nemotron tail beyond them.
    func makeHybridSession(
        language: String? = nil,
        fastChunkMs: Int = defaultFastChunkMs,
        voxtralDelayMs: Int = 960,
        valve: OverloadValve? = OverloadValve()
    ) -> TwoTierSession? {
        guard let nemotron, let voxtral else { return nil }
        return TwoTierSession(
            nemotron: nemotron, voxtral: voxtral,
            language: language, fastChunkMs: fastChunkMs, voxtralDelayMs: voxtralDelayMs,
            valve: valve
        )
    }

    /// Fast lane only (Nemotron).
    func makeFastSession(language: String? = nil, chunkMs: Int = defaultFastChunkMs) -> UtteranceSession? {
        guard let nemotron else { return nil }
        return NemotronOnlySession(nemotron, language: language, chunkMs: chunkMs)
    }

    /// Accurate lane only (Voxtral native streaming).
    func makeAccurateSession(voxtralDelayMs: Int = 960) -> UtteranceSession? {
        guard let voxtral else { return nil }
        return VoxtralOnlySession(voxtral, delayMs: voxtralDelayMs)
    }
}
