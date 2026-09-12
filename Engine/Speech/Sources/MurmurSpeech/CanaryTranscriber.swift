import Foundation
import FluidAudio
import MurmurCore

/// Serial, bounded audio processing shared by file and live Canary callers.
/// It never opens a microphone and never creates a queue of inference jobs.
public actor CanaryTranscriber {
    public enum Failure: Error { case busy, notPrepared }
    private let directory: URL
    private var runtime: CanaryRuntime?
    private var detector: VadManager?
    private var working = false
    private var generation = UUID()

    public init(modelsDirectory: URL = CanaryAssets.defaultDirectory) { directory = modelsDirectory }

    public func prepare(progress: @escaping @MainActor @Sendable (Progress) -> Void = { _ in }) async throws {
        guard !working else { throw Failure.busy }
        working = true; defer { working = false }
        let token = generation
        let root = try await CanaryAssets.prepare(at: directory, progress: progress)
        try Task.checkCancellation()
        let loaded = try await CanaryRuntime(modelsDirectory: root)
        let vad = try await VadManager(config: VadConfig(computeUnits: .cpuOnly))
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        runtime = loaded; detector = vad
    }

    public func processFile(url: URL, source: String, target: String? = nil,
        onProgress: @escaping @Sendable (Double, Double) async -> Void = { _, _ in },
        onBatch: @escaping @Sendable (Range<Int>, CanaryResult) async throws -> Void) async throws {
        let reader = try AudioFilePCMReader(url: url)
        try await process(source: source, target: target, nextFrame: { try reader.next() },
            onProgress: { await onProgress(Double($0) / 16_000, reader.duration) }, onBatch: onBatch)
    }

    public func process(source: String, target: String? = nil,
        nextFrame: () async throws -> [Float]?,
        onProgress: @escaping @Sendable (Int) async -> Void = { _ in },
        onBatch: @escaping @Sendable (Range<Int>, CanaryResult) async throws -> Void) async throws {
        guard !working else { throw Failure.busy }
        guard let runtime, let detector else { throw Failure.notPrepared }
        working = true; defer { working = false }
        let token = generation
        var vadState = VadStreamState.initial()
        try await AudioBatchProcessor.process(maximumSamples: CanaryRuntime.maxSamples,
            nextFrame: nextFrame,
            classify: { audio in
                let result = try await detector.processStreamingChunk(audio, state: vadState)
                vadState = result.state
                return result.probability >= 0.5
            }, onProgress: onProgress,
            onBatch: { [self] batch in
                let result = try await runtime.process(audio: batch.samples, sourceLanguage: source, targetLanguage: target)
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                try await onBatch(batch.range, result)
            })
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    public func close() {
        generation = UUID()
        runtime = nil; detector = nil
    }
}
