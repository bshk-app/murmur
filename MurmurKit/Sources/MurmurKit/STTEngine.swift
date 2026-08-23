import Foundation

/// Murmur's wrapper around `TwoTierEngine`. Loads models lazily per mode, then
/// opens a fresh session per utterance. MLX work is serialized on one queue.
final class STTEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "murmur.stt")
    private var engine: TwoTierEngine?
    private var session: UtteranceSession?
    private let languageCodesLock = NSLock()
    private var languageCodes = ["auto"]

    /// Ready to record in `mode` — its models are loaded and warmed.
    func isReady(_ mode: DictationMode) -> Bool {
        queue.sync { engine?.isReady(mode) ?? false }
    }

    var supportedLanguageCodes: [String] {
        languageCodesLock.lock()
        defer { languageCodesLock.unlock() }
        return languageCodes
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
        let codes = engine.supportedLanguageCodes
        languageCodesLock.lock()
        languageCodes = codes
        languageCodesLock.unlock()


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

    /// Open a clean session for a new utterance.
    func begin(language: String?, mode: DictationMode) {
        queue.sync {
            session = engine?.makeSession(for: mode, language: language)
        }
    }

    /// Stop the live draft. Capture leftover is still appended for the batch final.
    func releaseLive() {
        queue.sync { session?.releaseLive() }
    }

    /// Feed one 16 kHz mono chunk. The live model sees every sample so its
    /// streaming state stays continuous.
    @discardableResult
    func step(_ samples: [Float]) -> (confirmed: String, partial: String) {
        queue.sync {
            session?.step(samples) ?? ("", "")
        }
    }

    /// Flush and end the utterance; returns the batch-final transcript.
    func finish() -> String {
        queue.sync {
            let text = session?.finishText() ?? ""
            session = nil
            return text
        }
    }
}
