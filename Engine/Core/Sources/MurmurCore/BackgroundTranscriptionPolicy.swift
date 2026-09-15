import Foundation

/// What the phone has learned about its own speed, so the decision below rests on
/// measurement rather than a constant that rots with every model change.
public struct SpeechTimings: Codable, Sendable, Equatable {
    /// Decode seconds per second of audio. The unmeasured default is deliberately
    /// pessimistic: the first note after an install belongs in the foreground,
    /// where being slow costs nothing.
    public private(set) var realTimeFactor: Double
    /// Loading dominates a short note: measured at roughly twelve seconds cold and
    /// a third of a second warm.
    public private(set) var modelLoadSeconds: Double

    public init(realTimeFactor: Double = 1.0, modelLoadSeconds: Double = 12) {
        self.realTimeFactor = realTimeFactor
        self.modelLoadSeconds = modelLoadSeconds
    }

    /// Moved rather than replaced, so one slow run under memory pressure does not
    /// park every later note in the foreground.
    public mutating func record(audioSeconds: Double, decodeSeconds: Double, loadSeconds: Double) {
        guard audioSeconds > 0, decodeSeconds >= 0, loadSeconds >= 0 else { return }
        let observed = decodeSeconds / audioSeconds
        if measurements == 0 {
            realTimeFactor = observed
            modelLoadSeconds = loadSeconds
        } else {
            realTimeFactor += (observed - realTimeFactor) * 0.4
            modelLoadSeconds += (loadSeconds - modelLoadSeconds) * 0.4
        }
        measurements += 1
    }

    private var measurements = 0
}

/// Decides whether a recording that arrived while the phone was asleep is worth
/// transcribing there and then. Being cut off by the budget is not a disaster —
/// the job is checkpointed and resumes — but it wastes a model load and leaves a
/// half-finished note, so only work that clears the budget comfortably starts.
public enum BackgroundTranscriptionPolicy {
    public struct Estimate: Sendable {
        public let audioSeconds: Double
        public let realTimeFactor: Double
        public let modelLoadSeconds: Double
        public init(audioSeconds: Double, realTimeFactor: Double, modelLoadSeconds: Double) {
            self.audioSeconds = audioSeconds
            self.realTimeFactor = realTimeFactor
            self.modelLoadSeconds = modelLoadSeconds
        }
        public var seconds: Double { modelLoadSeconds + audioSeconds * realTimeFactor }
    }

    /// `margin` is the slack demanded on top of the estimate. Measurements vary
    /// with thermal state and memory pressure, and the cost of guessing high is
    /// only a wait, while guessing low wastes the whole wake-up.
    public static func fitsInBackground(_ estimate: Estimate, budgetSeconds: Double, margin: Double = 1.4) -> Bool {
        guard estimate.audioSeconds > 0, budgetSeconds > 0 else { return false }
        return estimate.seconds * margin <= budgetSeconds
    }
}
