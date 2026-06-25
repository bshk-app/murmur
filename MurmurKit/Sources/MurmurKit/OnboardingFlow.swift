import Foundation

/// Pure, UI-agnostic state + rules for the first-run onboarding wizard. The app's
/// `OnboardingModel` owns the real subsystems and consults this for every
/// transition and gate. Foundation-only so it unit-tests without MLX.
public enum OnboardingFlow {
    public enum Step: Int, CaseIterable, Sendable {
        case welcome, permissions, shortcut, download, tryIt, done
    }

    /// Known on-disk sizes (GB) of the two quantized models — for the progress UI.
    public static let fastGB = 0.6
    public static let accurateGB = 3.0
    public static var totalGB: Double { fastGB + accurateGB }   // 3.6

    public struct State: Sendable {
        public var step: Step = .welcome
        public var micGranted = false
        public var accessibilityGranted = false
        public var fastFraction = 0.0       // 0…1
        public var accurateFraction = 0.0   // 0…1
        public var didTry = false           // ≥1 successful try-it dictation
        public init() {}
    }

    /// Continue is allowed unless the current step has an unmet requirement.
    /// Mic is required (no dictation without it); Accessibility is *not* gated
    /// (skippable — HUD-only works without it).
    public static func canContinue(_ s: State) -> Bool {
        switch s.step {
        case .permissions: return s.micGranted
        case .download:    return s.fastFraction >= 1 && s.accurateFraction >= 1
        case .tryIt:       return s.didTry
        case .welcome, .shortcut, .done: return true
        }
    }

    public static func next(_ step: Step) -> Step {
        Step(rawValue: min(step.rawValue + 1, Step.done.rawValue)) ?? .done
    }
    public static func back(_ step: Step) -> Step {
        Step(rawValue: max(step.rawValue - 1, 0)) ?? .welcome
    }

    public struct DownloadMetrics: Sendable {
        public let downloadedGB: Double
        public let totalGB: Double
        public let remainingGB: Double
        public let done: Bool
    }
    public static func downloadMetrics(fast: Double, accurate: Double) -> DownloadMetrics {
        let dl = fastGB * fast + accurateGB * accurate
        let done = fast >= 1 && accurate >= 1
        return DownloadMetrics(downloadedGB: dl, totalGB: totalGB,
                               remainingGB: max(0, totalGB - dl), done: done)
    }
}
