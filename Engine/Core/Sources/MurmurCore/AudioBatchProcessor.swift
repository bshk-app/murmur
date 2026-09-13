import Foundation

/// Serial, backpressured driver shared by file import and bounded live sources.
/// The source supplies mono 16 kHz PCM in 4096-sample frames, with an optional
/// shorter final frame. Silence is intentionally excluded by AudioFileBatcher.
/// Windows never overlap; forced cuts can split words. Text assembly must not
/// remove repeated words heuristically, since they may be legitimate speech.
public enum AudioBatchProcessor {
    public enum InputError: Error, Equatable {
        case invalidFrameSize
        case frameAfterTail
        case invalidResumeBoundary
    }

    /// `onBatch` is awaited before pulling more audio, so inference cannot build
    /// an unbounded queue. Live sources must themselves bound their capture queue
    /// and report overflow rather than silently dropping audio.
    /// Resume offsets must be committed boundaries from the same VAD/window policy.
    /// A callback that awaits inference must check cancellation again before
    /// committing its result; cancellation cannot undo an external side effect.
    public static func process(
        maximumSamples: Int = AudioFileBatcher.maximumBatchSamples,
        completedThrough: Int = 0,
        nextFrame: () async throws -> [Float]?,
        classify: ([Float]) async throws -> Bool,
        onProgress: (Int) async -> Void = { _ in },
        onBatch: (AudioFileBatch) async throws -> Void
    ) async throws {
        guard completedThrough >= 0 else { throw InputError.invalidResumeBoundary }
        var batcher = AudioFileBatcher(maximumSamples: maximumSamples)
        var sawTail = false
        func emit(_ batch: AudioFileBatch) async throws {
            guard batch.range.upperBound > completedThrough else { return }
            guard batch.range.lowerBound >= completedThrough else { throw InputError.invalidResumeBoundary }
            try Task.checkCancellation()
            try await onBatch(batch)
            try Task.checkCancellation()
        }
        while true {
            try Task.checkCancellation()
            guard let frame = try await nextFrame() else { break }
            try Task.checkCancellation()
            guard !sawTail else { throw InputError.frameAfterTail }
            guard !frame.isEmpty, frame.count <= AudioFileBatcher.frameSamples else { throw InputError.invalidFrameSize }
            sawTail = frame.count < AudioFileBatcher.frameSamples
            let padded = sawTail ? frame + Array(repeating: 0, count: AudioFileBatcher.frameSamples - frame.count) : frame
            let speech = try await classify(padded)
            try Task.checkCancellation()
            if let batch = batcher.append(frame, isSpeech: speech) { try await emit(batch) }
            await onProgress(batcher.samplesRead)
        }
        if let batch = batcher.finish() { try await emit(batch) }
        try Task.checkCancellation()
        guard completedThrough <= batcher.samplesRead else { throw InputError.invalidResumeBoundary }
    }
}
