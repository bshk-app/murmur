import Foundation
import MLX
import MLXAudioVAD

/// Murmur's wrapper around `TwoTierEngine`, with a Silero VAD speech gate in front.
/// Loads models lazily per mode (Fast doesn't pull the 4 B Voxtral), then opens a
/// fresh session + `SpeechGate` per utterance. Stepping is serialized on one queue
/// — MLX is not concurrency-safe, and the VAD shares that queue.
final class STTEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "murmur.stt")
    private var engine: TwoTierEngine?
    private var session: UtteranceSession?   // two-tier, Nemotron-only or Voxtral-only per mode
    private var vad: SileroVAD?              // shared model; a fresh SpeechGate wraps it per utterance
    private var vadLoaded = false
    private var gate: SpeechGate?

    /// Ready to record in `mode` — its models are loaded and warmed.
    func isReady(_ mode: DictationMode) -> Bool {
        queue.sync { engine?.isReady(mode) ?? false }
    }

    /// Download (first run) + load + warm ONLY the models `mode` needs. Idempotent
    /// and memoized, so switching modes loads just the missing model. Loads the
    /// Silero gate once (best-effort: run ungated rather than fail the pipeline).
    func prepare(_ mode: DictationMode) async throws {
        let engine = queue.sync { () -> TwoTierEngine in
            if let existing = self.engine { return existing }
            let made = TwoTierEngine()                   // caps Metal memory in init
            self.engine = made
            return made
        }
        try await engine.prepare(mode)                   // async fromPretrained (memoized)

        if !queue.sync(execute: { vadLoaded }) {
            let silero = try? await SileroVAD.fromPretrained("mlx-community/silero-vad")
            queue.sync {
                if let silero, let st = try? silero.initialState(sampleRate: 16000) {
                    _ = try? silero.feed(chunk: MLXArray([Float](repeating: 0, count: 512)), state: st)
                }
                vad = silero
                vadLoaded = true
            }
        }

        // Warm the mode's models on our queue — the first inference JIT-compiles
        // every Metal kernel (tens of seconds of stalls); do it here, off the first
        // dictation. Re-warming an already-JIT'd model is cheap.
        queue.sync {
            if let warm = engine.makeSession(for: mode, language: nil) {
                _ = warm.step([Float](repeating: 0, count: 16000))
                _ = warm.finishText()
            }
        }
    }

    /// Open a clean session + gate for a new utterance, per the chosen model mode.
    func begin(language: String?, mode: DictationMode) {
        queue.sync {
            session = engine?.makeSession(for: mode, language: language)
            gate = vad.flatMap { try? SpeechGate(vad: $0) }
        }
    }

    /// Feed one 16 kHz mono chunk — but only if the gate says it's speech. On a
    /// gated (silent) chunk, return the current text without advancing the STT,
    /// so silence neither costs compute nor produces hallucinated finals.
    @discardableResult
    func step(_ samples: [Float]) -> (confirmed: String, partial: String) {
        queue.sync {
            guard let session else { return ("", "") }
            if let gate, !gate.shouldFeed(samples) {
                return session.currentText
            }
            return session.step(samples)
        }
    }

    /// Flush and end the utterance; returns the final transcript (Voxtral text).
    func finish() -> String {
        queue.sync {
            let text = session?.finishText() ?? ""
            session = nil
            gate = nil
            return text
        }
    }
}
