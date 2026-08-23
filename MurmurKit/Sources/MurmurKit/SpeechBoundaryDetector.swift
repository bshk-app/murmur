import Foundation
@preconcurrency import MLX
import MLXAudioVAD

/// Silero, reduced to the one question the caption policy asks: is this 512-sample
/// frame speech?
///
/// Streaming state is carried across frames, so this is stateful and — like every
/// MLX call in Murmur — must run on the engine's serial queue.
final class SpeechBoundaryDetector {
    static let frameSamples = 512      // 32 ms @ 16 kHz; Silero's fixed chunk
    static let defaultRepo = "mlx-community/silero-vad"

    private let vad: SileroVAD
    private let threshold: Float
    private var state: SileroVADStreamingState?

    init(vad: SileroVAD, threshold: Float = 0.5) {
        self.vad = vad
        self.threshold = threshold
    }

    static func load(repo: String = defaultRepo) async throws -> SpeechBoundaryDetector {
        SpeechBoundaryDetector(vad: try await SileroVAD.fromPretrained(repo))
    }

    /// One frame in, one verdict out. A Silero failure must not mute captions, so
    /// it degrades to "speech": the live lane keeps running and phrases close on
    /// the safety cap instead of the endpoint.
    func isSpeech(_ frame: [Float]) -> Bool {
        guard frame.count == Self.frameSamples else { return true }
        do {
            let (prob, next) = try vad.feed(chunk: MLXArray(frame), state: state)
            state = next
            return prob.item(Float.self) >= threshold
        } catch {
            return true
        }
    }

    /// Forget the conversation so far — used when a caption session ends.
    func reset() { state = nil }
}
