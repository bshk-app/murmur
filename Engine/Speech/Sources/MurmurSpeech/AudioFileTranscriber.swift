import Foundation
import AVFoundation
import FluidAudio
import MurmurCore

/// Decodes and resamples incrementally, including compressed/stereo recordings.
/// At most one input block and one 4096-sample output block are resident.
public final class AudioFilePCMReader {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var ended = false
    public let duration: Double
    public init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.processingFormat.sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else { throw CocoaError(.fileReadCorruptFile) }
        self.converter = converter; self.input = input; self.output = output
        duration = Double(file.length) / file.processingFormat.sampleRate
    }
    public func next() throws -> [Float]? {
        guard !ended else { return nil }
        var conversionError: NSError?, readError: Error?
        output.frameLength = 0
        let status = converter.convert(to: output, error: &conversionError) { [self] requested, state in
            if file.framePosition >= file.length { state.pointee = .endOfStream; return nil }
            do {
                try file.read(into: input, frameCount: min(requested, input.frameCapacity))
                state.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                return input.frameLength == 0 ? nil : input
            } catch { readError = error; state.pointee = .endOfStream; return nil }
        }
        if let readError { throw readError }
        if let conversionError { throw conversionError }
        if status == .error { throw CocoaError(.fileReadCorruptFile) }
        if status == .endOfStream { ended = true }
        if output.frameLength > 0, let channel = output.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
        guard ended else { throw CocoaError(.fileReadCorruptFile) }
        return nil
    }
}

/// One accurate recognizer, CPU VAD and serial bounded batches. No microphone,
/// real-time replay, draft engine, whole-file PCM array or unbounded task queue.
public actor AudioFileTranscriber {
    private let lane: CoreMLSpeechLane
    private let maximumSamples: Int
    public init(choice: SpeechModelChoice, modelsRoot: URL) {
        maximumSamples = (choice.usesGPU ? 12 : 20) * 16_000
        lane = CoreMLSpeechLane(choice: choice, modelsRoot: modelsRoot)
    }
    public func run(url: URL, language: String, completedThrough: Int = 0,
                    onReady: @escaping @Sendable () async -> Void = {},
                    onProgress: @escaping @Sendable (Double, Double) async -> Void,
                    onSegment: @escaping @Sendable (AudioFileSegment, Double) async throws -> Void) async throws {
        let reader = try AudioFilePCMReader(url: url)
        try Task.checkCancellation()
        await onProgress(0, reader.duration)
        try await lane.load()
        let vad = try await VadManager(config: VadConfig(computeUnits: .cpuOnly))
        await onReady()
        var state = VadStreamState.initial()
        try await Self.process(reader: reader, completedThrough: completedThrough, maximumSamples: maximumSamples,
            classify: { samples in
                let value = try await vad.processStreamingChunk(samples, state: state)
                state = value.state
                return value.probability >= 0.5
            }, transcribe: { [lane] samples in try await lane.transcribe(samples, language: language) },
            onProgress: onProgress, onSegment: onSegment)
    }

    /// Test seam for long-file decoding, exact batch boundaries and resume.
    /// Classifier and recognizer are awaited serially; no work is queued ahead.
    static func process(reader: AudioFilePCMReader, completedThrough: Int = 0, maximumSamples: Int = AudioFileBatcher.maximumBatchSamples,
                        classify: ([Float]) async throws -> Bool,
                        transcribe: ([Float]) async throws -> String,
                        onProgress: (Double, Double) async -> Void = { _, _ in },
                        onSegment: (AudioFileSegment, Double) async throws -> Void) async throws {
        var lastProgress = Date.distantPast
        try await AudioBatchProcessor.process(maximumSamples: maximumSamples, completedThrough: completedThrough,
            nextFrame: { try reader.next() }, classify: classify,
            onProgress: { samplesRead in
                if Date().timeIntervalSince(lastProgress) >= 0.25 {
                    await onProgress(min(reader.duration, Double(samplesRead)/16_000), reader.duration)
                    lastProgress = Date()
                }
            }, onBatch: { batch in
                let text = try await transcribe(batch.samples)
                try Task.checkCancellation()
                try await onSegment(.init(startSample: batch.range.lowerBound, endSample: batch.range.upperBound, text: text), reader.duration)
            })
        await onProgress(reader.duration, reader.duration)
    }
    public func close() async { await lane.close() }
}
