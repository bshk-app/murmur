import MurmurCore
import Foundation
@preconcurrency import MLX
import MLXAudioVAD

/// Silero, reduced to the one question the caption policy asks: is this 512-sample
/// frame speech?
///
/// Streaming state is carried across frames, so this is stateful and — like every
/// MLX call in Murmur — must run on the engine's serial queue.
public final class SpeechBoundaryDetector {
    static let frameSamples = 512      // 32 ms @ 16 kHz; Silero's fixed chunk
    public static let defaultRepo = "mlx-community/silero-vad"

    private let vad: SileroVAD
    private let threshold: Float
    private var state: SileroVADStreamingState?
    private(set) var lastProbability: Float?
    private(set) var lastError: String?

    public init(vad: SileroVAD, threshold: Float = 0.5) {
        self.vad = vad
        self.threshold = threshold
    }

    public static func load(repo: String = defaultRepo) async throws -> SpeechBoundaryDetector {
        SpeechBoundaryDetector(vad: try await SileroVAD.fromPretrained(repo))
    }

    /// One frame in, one verdict out. A Silero failure must not mute captions, so
    /// it degrades to "speech": the live lane keeps running and phrases close on
    /// the safety cap instead of the endpoint.
    public func isSpeech(_ frame: [Float]) -> Bool {
        guard frame.count == Self.frameSamples else { return true }
        do {
            let (prob, next) = try vad.feed(chunk: MLXArray(frame), state: state)
            state = next
            let probability = prob.item(Float.self)
            lastProbability = probability
            lastError = nil
            return probability >= threshold
        } catch {
            lastProbability = nil
            lastError = String(describing: error)
            return true
        }
    }

    /// Compile the first forward while the app is loading, then clear the state so
    /// live speech starts from the same state as a never-warmed detector.
    public func warmUp() {
        Self.performWarmUp(
            frameSamples: Self.frameSamples,
            feed: { _ = isSpeech($0) },
            reset: reset
        )
    }

    /// Pure sequencing seam: one correctly sized silent frame, then reset.
    public static func performWarmUp(
        frameSamples: Int,
        feed: ([Float]) -> Void,
        reset: () -> Void
    ) {
        feed([Float](repeating: 0, count: frameSamples))
        reset()
    }

    /// Forget the conversation so far — used when a caption session ends.
    public func reset() { state = nil; lastProbability = nil; lastError = nil }
}
