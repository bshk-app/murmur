import Foundation

/// The UI-agnostic dictation pipeline shared by the menu-bar app and the CLI:
/// load the two-tier models (with warm-up), capture the mic in 480 ms chunks,
/// stream `(confirmed, partial)` updates, and flush a final transcript on stop.
///
/// No SwiftUI, no hotkey library, no text injection — callers wire those. The
/// only difference between the app and the CLI is who drives `start()`/`stop()`
/// and what they do with the transcript.
///
/// `@unchecked Sendable`: `onUpdate` fires on the mic capture queue and `stop()`
/// is meant to be called off the main thread; `start()`/`stop()` never overlap
/// (the caller's state machine guarantees it).
public final class DictationSession: @unchecked Sendable {
    private let engine = STTEngine()
    private var mic = MicCapture()

    /// Live update per fed chunk: `(confirmed, provisional)`. Called on the mic
    /// capture queue — hop to your UI thread as needed.
    public var onUpdate: ((_ confirmed: String, _ partial: String) -> Void)?

    public init() {}

    /// Ready to record in `mode` — its models are loaded and warmed.
    public func isReady(_ mode: DictationMode = .hybrid) -> Bool { engine.isReady(mode) }

    /// Download (first run) + load + warm up ONLY the models `mode` needs. Heavy;
    /// await before `start(mode:)`. Defaults to hybrid (both lanes) for the CLI.
    public func load(mode: DictationMode = .hybrid) async throws {
        try await engine.prepare(mode)
    }

    /// Surface the microphone permission prompt early (no-op once granted).
    public func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void = { _ in }) {
        MicCapture.requestPermission(completion)
    }

    /// Begin a fresh utterance and start capturing, with the chosen model mode.
    public func start(mode: DictationMode = .hybrid) throws {
        engine.begin(language: nil, mode: mode)
        mic.onChunk = { [weak self] chunk in
            guard let self else { return }
            let (confirmed, partial) = self.engine.step(chunk)
            self.onUpdate?(confirmed, partial)
        }
        try mic.start()
    }

    /// Stop capture, flush, and return the final transcript. Blocks while the
    /// backlog drains — call off the main thread.
    @discardableResult
    public func stop() -> String {
        _ = mic.stop()
        let final = engine.finish()
        mic = MicCapture()                               // fresh engine for the next gesture
        return final
    }

    /// Offline transcription of pre-loaded 16 kHz mono samples, feeding the same
    /// 480 ms chunks the mic path uses and timing the STT compute. For
    /// benchmarking against the CLI on a fixed file (no mic involved).
    public func transcribeOffline(_ samples: [Float], chunkSamples: Int = 7680, mode: DictationMode = .hybrid) -> OfflineResult {
        engine.begin(language: nil, mode: mode)
        let wall0 = ProcessInfo.processInfo.systemUptime
        var compute = 0.0
        var i = 0
        while i < samples.count {
            let end = min(i + chunkSamples, samples.count)
            let chunk = Array(samples[i ..< end])
            let t0 = ProcessInfo.processInfo.systemUptime
            _ = engine.step(chunk)
            compute += ProcessInfo.processInfo.systemUptime - t0
            i = end
        }
        let tf = ProcessInfo.processInfo.systemUptime
        let text = engine.finish()
        compute += ProcessInfo.processInfo.systemUptime - tf
        let wall = ProcessInfo.processInfo.systemUptime - wall0
        return OfflineResult(
            text: text,
            audioSeconds: Double(samples.count) / 16000.0,
            computeSeconds: compute,
            wallSeconds: wall
        )
    }
}

public struct OfflineResult: Sendable {
    public let text: String
    public let audioSeconds: Double
    public let computeSeconds: Double   // sum of step + finish time
    public let wallSeconds: Double      // total incl. chunk slicing overhead
    public var rtf: Double { audioSeconds > 0 ? computeSeconds / audioSeconds : 0 }
}
