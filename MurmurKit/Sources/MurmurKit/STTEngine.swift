import Foundation
import MLX
import MLXAudioVAD

/// Murmur's wrapper around the fork's `TwoTierEngine`, with a Silero VAD speech
/// gate in front. Loads the models once, then opens a fresh `TwoTierSession` +
/// `SpeechGate` per utterance. Stepping is serialized on one queue — MLX is not
/// concurrency-safe, and the VAD shares that queue.
final class STTEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "murmur.stt")
    private var loader: TwoTierEngine?
    private var session: UtteranceSession?   // two-tier, Nemotron-only or Voxtral-only per mode
    private var vad: SileroVAD?              // shared model; a fresh SpeechGate wraps it per utterance
    private var gate: SpeechGate?

    var isLoaded: Bool { queue.sync { loader != nil } }

    /// Heavy; downloads the models from Hugging Face on first run, caps Metal memory.
    func load() async throws {
        let engine = try await TwoTierEngine.load()
        // The Silero gate is best-effort: if it can't load, run ungated rather
        // than fail the whole pipeline.
        let silero = try? await SileroVAD.fromPretrained("mlx-community/silero-vad")
        queue.sync {
            // Warm up the STT — the first inference JIT-compiles every Metal kernel
            // (tens of seconds of stalls); do it here, off the first dictation.
            let warm = engine.makeSession(language: nil)
            _ = warm.step([Float](repeating: 0, count: 16000))
            _ = warm.finish()
            // Warm the VAD on one frame of silence too.
            if let silero, let st = try? silero.initialState(sampleRate: 16000) {
                _ = try? silero.feed(chunk: MLXArray([Float](repeating: 0, count: 512)), state: st)
            }
            vad = silero
            loader = engine
        }
    }

    /// Open a clean session + gate for a new utterance, per the chosen model mode.
    func begin(language: String?, mode: DictationMode) {
        queue.sync {
            switch mode {
            case .hybrid:   session = loader?.makeSession(language: language)
            case .fast:     session = loader?.makeFastSession(language: language)
            case .accurate: session = loader?.makeAccurateSession()
            }
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
