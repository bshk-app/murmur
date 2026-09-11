import Foundation

/// Correction cadence is independent of acoustic context. Adjacent closed
/// segments are decoded again together; a gap or the model limit starts a group.
/// Results replace their covered IDs instead of concatenating overlapping words.
public struct CorrectionContext {
    public struct Request {
        public let id: UInt64
        public let segmentIDs: [UInt64]
        public let samples: [Float]
        public let range: Range<Int>
    }

    let maxSamples: Int
    private var endSample: Int?
    private var samples: [Float] = []
    private var ids: [UInt64] = []

    public init(maxSamples: Int = 28 * 16_000) { self.maxSamples = maxSamples }

    public mutating func append(id: UInt64, range: Range<Int>, audio: [Float]) -> Request {
        if endSample != range.lowerBound || samples.count + audio.count > maxSamples {
            samples.removeAll(keepingCapacity: true)
            ids.removeAll(keepingCapacity: true)
        }
        samples.append(contentsOf: audio)
        ids.append(id)
        endSample = range.upperBound
        return Request(id: id, segmentIDs: ids, samples: samples, range: (range.upperBound - samples.count)..<range.upperBound)
    }
    public var startSample: Int? { endSample.map { $0 - samples.count } }
}
