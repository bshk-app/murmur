import Foundation

/// Brings quiet speech up to a level the VAD and the live model handle well.
///
/// The measurement audio mode switches the system's own gain control off, so a
/// phone lying on a table hands over speech far below full scale. This only ever
/// boosts: a peak follower with instant attack keeps each output sample at or
/// below `target` unless the input itself was louder, so nothing new can clip.
public struct AutomaticGain: Sendable {
    public let target: Float
    public let maximumGain: Float
    private let release: Float
    private var envelope: Float

    public init(target: Float = 0.25, maximumGain: Float = 10, releaseSeconds: Double = 1.5, sampleRate: Double = 16_000) {
        self.target = target
        self.maximumGain = maximumGain
        release = Float(exp(-1 / (releaseSeconds * sampleRate)))
        envelope = target / maximumGain
    }

    public mutating func process(_ samples: inout [Float]) {
        for index in samples.indices {
            envelope = max(abs(samples[index]), envelope * release)
            let gain = envelope * maximumGain <= target ? maximumGain : max(1, target / envelope)
            samples[index] *= gain
        }
    }
}

/// Input level for a meter: decibels, so ordinary speech moves it visibly.
public enum InputLevel {
    public static let floor: Float = 0.05
    private static let rangeDecibels: Float = 60

    public static func meter(peak: Float) -> Float {
        guard peak > 0 else { return floor }
        return min(1, max(floor, 1 + 20 * log10(peak) / rangeDecibels))
    }
}
