import Foundation
import MLX
import MLXAudioSTT

/// Offline comparison probe for a Parakeet TDT accurate lane.
///
/// Not part of dictation. It exists to answer one question with numbers instead
/// of opinion: can a 0.6 B CTC/TDT model, with its Conformer encoder on the
/// Neural Engine, stand in for the 4 B Voxtral without losing the transcript?
///
/// Why it is worth asking. Measured on this pipeline, cost tracks seconds of
/// audio rather than tokens produced, so the expense is forward passes, not
/// decoding — and on a base M1 the accurate lane runs at RTF 2.2, more than
/// twice too slow to keep up with speech. The ANE is a separate engine from the
/// GPU, so moving the encoder there removes both the compute and the queueing
/// against the fast lane, which MLX forces to be serial.
public enum ParakeetProbe {
    public struct Result: Sendable {
        public let text: String
        public let audioSeconds: Double      // one pass
        public let computeSeconds: Double    // best pass
        public let passes: Int
        public let wallSeconds: Double       // all timed passes end to end
        public var rtf: Double { audioSeconds > 0 ? computeSeconds / audioSeconds : 0 }
        /// Total audio pushed through during the timed window — the denominator
        /// for "power per second of audio".
        public var audioProcessedSeconds: Double { audioSeconds * Double(passes) }
    }

    public static let defaultRepo = "mlx-community/parakeet-tdt-0.6b-v3"

    /// Load once, transcribe many. A benchmark host feeds a whole dataset through
    /// one process, so the model has to outlive a single call — otherwise every
    /// sample's measurement includes loading it.
    public static func makeTranscriber(
        repo: String = defaultRepo,
        ane: Bool
    ) async throws -> ([Float]) -> String {
        let model = try await ParakeetModel.fromPretrained(repo, aneEncoder: ane ? .on : .off)
        return { samples in model.generate(audio: MLXArray(samples)).text }
    }

    /// Transcribe 16 kHz mono samples once, timed. The first pass is discarded:
    /// it JIT-compiles Metal kernels and, with `ane`, compiles the CoreML model,
    /// which would otherwise be measured as if it were per-utterance cost.
    /// `passes` repeats the timed run back to back. One pass is enough to time,
    /// but not to sample power: a run that finishes in half a second gives the
    /// sampler nothing to average, so power comparisons need the process busy for
    /// a stretch.
    public static func transcribe(
        _ samples: [Float],
        repo: String = defaultRepo,
        ane: Bool,
        passes: Int = 1
    ) async throws -> Result {
        let model = try await ParakeetModel.fromPretrained(repo, aneEncoder: ane ? .on : .off)
        let audio = MLXArray(samples)

        _ = model.generate(audio: audio)                       // warm-up, not timed

        var best = Double.greatestFiniteMagnitude
        var text = ""
        let wall0 = ProcessInfo.processInfo.systemUptime
        for _ in 0 ..< max(1, passes) {
            let t0 = ProcessInfo.processInfo.systemUptime
            let out = model.generate(audio: audio)
            best = min(best, ProcessInfo.processInfo.systemUptime - t0)
            text = out.text
        }
        let wall = ProcessInfo.processInfo.systemUptime - wall0

        return Result(text: text,
                      audioSeconds: Double(samples.count) / 16000.0,
                      computeSeconds: best,
                      passes: max(1, passes),
                      wallSeconds: wall)
    }
}
