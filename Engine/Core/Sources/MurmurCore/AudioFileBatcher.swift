import Foundation

public struct AudioFileBatch: Sendable {
    public let range: Range<Int>
    public let samples: [Float]
}

/// Bounded speech-only audio batches. No overlap, no growing whole-file buffer.
public struct AudioFileBatcher {
    public static let sampleRate = 16_000
    public static let frameSamples = 4_096
    public static let maximumBatchSamples = 20 * sampleRate
    private var policy: SpeechBoundaryPolicy
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var openStart: Int?
    public private(set) var samplesRead = 0
    public var bufferedSamples: Int { buffer.count }
    public init(maximumSamples: Int = Self.maximumBatchSamples) {
        precondition(maximumSamples >= Self.frameSamples * 3 && maximumSamples <= Self.maximumBatchSamples)
        policy = SpeechBoundaryPolicy(frameSamples: Self.frameSamples, preRollSamples: Self.frameSamples,
            endpointSilenceFrames: 3, maxEpochSamples: maximumSamples - Self.frameSamples)
    }

    public mutating func append(_ samples: [Float], isSpeech: Bool) -> AudioFileBatch? {
        precondition(!samples.isEmpty && samples.count <= Self.frameSamples)
        buffer.append(contentsOf: samples); samplesRead += samples.count
        let batch = handle(policy.frame(isSpeech: isSpeech))
        trim()
        return batch
    }
    public mutating func finish() -> AudioFileBatch? {
        let batch = handle(policy.finish(endSample: samplesRead))
        buffer.removeAll(); bufferStart = samplesRead; openStart = nil
        return batch
    }
    private mutating func handle(_ event: SpeechBoundaryEvent?) -> AudioFileBatch? {
        guard let event else { return nil }
        switch event {
        case .opened(let start): openStart = start; return nil
        case .closed(let range, let forced):
            let end = min(samplesRead, range.upperBound)
            openStart = forced && range.upperBound < policy.consumedSamples ? range.upperBound : nil
            guard end > range.lowerBound else { return nil }
            let audio = Array(buffer[(range.lowerBound-bufferStart)..<(end-bufferStart)])
            return AudioFileBatch(range: range.lowerBound..<end, samples: audio)
        }
    }
    private mutating func trim() {
        let keepFrom = openStart ?? max(0, samplesRead - Self.frameSamples * 2)
        let count = max(0, min(buffer.count, keepFrom - bufferStart))
        if count > 0 { buffer.removeFirst(count); bufferStart += count }
    }
}

public struct AudioFileSegment: Codable, Sendable {
    public let startSample: Int
    public let endSample: Int
    public let text: String
    public init(startSample: Int, endSample: Int, text: String) {
        self.startSample = startSample; self.endSample = endSample; self.text = text
    }
}
