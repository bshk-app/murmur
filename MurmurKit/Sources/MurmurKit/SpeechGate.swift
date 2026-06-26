import Foundation
import MLX
import MLXAudioVAD

/// Streaming speech gate over Silero VAD (16 kHz, 32 ms / 512-sample frames).
/// Decides, per 480 ms mic chunk, whether to feed it to the STT: skip leading
/// silence, bridge short pauses (hangover), drop long trailing silence — so the
/// STT only ever sees speech. That kills hallucinated finals on silence and
/// saves the compute of running two big models on nothing.
///
/// Why Silero (benched): under additive white noise its speech ratio barely
/// moves (no false-triggering), it's already in the fork we depend on (zero new
/// public dependency), runs on ANE, and costs <0.2 ms/frame.
///
/// NOT concurrency-safe (MLX): drive it from the STT serial queue only.
final class SpeechGate {
    private let vad: SileroVAD
    private var state: SileroVADStreamingState
    private let threshold: Float
    private let hangoverChunks: Int      // all-silence chunks still fed after speech (bridges pauses)
    private let frame = 512              // Silero 16 kHz chunk (32 ms)
    private var silentRun = 0
    private(set) var started = false     // any speech seen this utterance

    init(vad: SileroVAD, threshold: Float = 0.5, hangoverChunks: Int = 2) throws {
        self.vad = vad
        self.threshold = threshold
        self.hangoverChunks = hangoverChunks
        self.state = try vad.initialState(sampleRate: 16000)
    }

    /// Does this 480 ms chunk contain speech? Runs Silero over its 512-sample
    /// frames, threading the LSTM state; one `asArray` at the end forces a single
    /// evaluation of the whole frame chain (no per-frame GPU→CPU sync in the loop).
    private func hasSpeech(_ chunk: [Float]) -> Bool {
        var probs: [MLXArray] = []
        var i = 0
        do {
            while i + frame <= chunk.count {
                let x = MLXArray(Array(chunk[i ..< i + frame]))
                let (prob, next) = try vad.feed(chunk: x, state: state, sampleRate: 16000)
                probs.append(prob.reshaped([1]))
                state = next
                i += frame
            }
        } catch {
            return true                 // fail-open: a VAD error must never drop audio
        }
        guard !probs.isEmpty else { return false }
        let vals = concatenated(probs, axis: 0).asArray(Float.self)
        return vals.contains { $0 > threshold }
    }

    /// Gate decision for a 480 ms chunk: should the STT consume it?
    func shouldFeed(_ chunk: [Float]) -> Bool {
        if hasSpeech(chunk) {
            silentRun = 0
            started = true
            return true
        }
        if !started { return false }    // leading silence — STT hasn't started yet
        silentRun += 1
        return silentRun <= hangoverChunks   // bridge a short pause, then gate off
    }
}
