import Foundation
import MLX
import MLXAudioSTT

/// Murmur's two-tier composition policy. Loads the fast (Nemotron) + accurate
/// (Voxtral) models, caps Metal memory, and vends a fresh `TwoTierSession` per
/// utterance (a session accumulates text, so each dictation needs a clean one).
///
/// This is **application** policy — which two models, how to merge them, the
/// memory budget — not a library primitive, so it lives in MurmurKit, built on
/// the library's public streaming primitives (`fromPretrained` /
/// `makeStreamSession`).
public final class TwoTierEngine {
    public static let defaultNemotronRepo = "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
    public static let defaultVoxtralRepo = "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"

    private let nemotron: NemotronASRModel
    private let voxtral: VoxtralRealtimeModel

    private init(nemotron: NemotronASRModel, voxtral: VoxtralRealtimeModel) {
        self.nemotron = nemotron
        self.voxtral = voxtral
    }

    /// Download (first run) and load both models. Caps Metal memory so an
    /// unbounded MLX run can't OOM-reboot the machine.
    public static func load(
        nemotronRepo: String = defaultNemotronRepo,
        voxtralRepo: String = defaultVoxtralRepo,
        memoryLimitBytes: Int = 18 * 1024 * 1024 * 1024
    ) async throws -> TwoTierEngine {
        GPU.set(memoryLimit: memoryLimitBytes, relaxed: false)
        let nemotron = try await NemotronASRModel.fromPretrained(nemotronRepo)
        let voxtral = try await VoxtralRealtimeModel.fromPretrained(voxtralRepo)
        return TwoTierEngine(nemotron: nemotron, voxtral: voxtral)
    }

    /// A fresh session for one utterance. `confirmed` = Voxtral finals,
    /// `partial` = Nemotron tail beyond Voxtral's coverage.
    public func makeSession(
        language: String? = nil,
        fastChunkMs: Int = 80,
        voxtralDelayMs: Int = 960
    ) -> TwoTierSession {
        TwoTierSession(
            nemotron: nemotron, voxtral: voxtral,
            language: language, fastChunkMs: fastChunkMs, voxtralDelayMs: voxtralDelayMs
        )
    }

    /// Fast lane only (Nemotron). Internal — STTEngine vends it per `DictationMode`.
    func makeFastSession(language: String? = nil, chunkMs: Int = 80) -> UtteranceSession {
        NemotronOnlySession(nemotron, language: language, chunkMs: chunkMs)
    }

    /// Accurate lane only (Voxtral native streaming).
    func makeAccurateSession(voxtralDelayMs: Int = 960) -> UtteranceSession {
        VoxtralOnlySession(voxtral, delayMs: voxtralDelayMs)
    }
}
