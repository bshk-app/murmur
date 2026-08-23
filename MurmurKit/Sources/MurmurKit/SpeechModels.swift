import Foundation

/// One loaded set of speech models, shared by every pipeline that needs it.
///
/// Murmur runs dictation and captions from the same weights: Nemotron plus
/// Parakeet is roughly 3.4 GB, and each engine also sets its own Metal memory
/// cap, so a second copy is not a tuning regression — it is the difference
/// between the app working and the machine swapping. An app that offers both
/// modes therefore builds one of these and hands it to both sessions.
///
/// A process driving a single pipeline — `murmur-cli` — can ignore this type and
/// use the sessions' convenience initialisers, which each make their own stack.
public final class SpeechModels: @unchecked Sendable {
    /// Internal on purpose: the loading, warm-up and queue discipline are
    /// MurmurKit's business, and callers only need to pass this object around.
    let engine: STTEngine

    public init() {
        self.engine = STTEngine()
    }
}
