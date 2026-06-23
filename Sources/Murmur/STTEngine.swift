import Foundation
import MLXAudioSTT

/// Murmur's wrapper around the fork's `TwoTierEngine`. Loads the models once,
/// then opens a fresh `TwoTierSession` per utterance. Stepping is serialized on
/// one queue — MLX is not concurrency-safe.
final class STTEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "murmur.stt")
    private var loader: TwoTierEngine?
    private var session: TwoTierSession?

    var isLoaded: Bool { queue.sync { loader != nil } }

    /// Heavy; downloads the models from Hugging Face on first run, caps Metal memory.
    func load() async throws {
        let engine = try await TwoTierEngine.load()
        queue.sync { loader = engine }
    }

    /// Open a clean session for a new utterance.
    func begin(language: String?) {
        queue.sync { session = loader?.makeSession(language: language) }
    }

    /// Feed one 16 kHz mono chunk; returns the current (confirmed, partial) split.
    @discardableResult
    func step(_ samples: [Float]) -> (confirmed: String, partial: String) {
        queue.sync { session?.step(samples) ?? ("", "") }
    }

    /// Flush and end the utterance; returns the final transcript (Voxtral text).
    func finish() -> String {
        queue.sync {
            let text = session?.finish().confirmed ?? ""
            session = nil
            return text
        }
    }
}
