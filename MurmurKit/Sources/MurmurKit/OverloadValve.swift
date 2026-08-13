import Foundation

/// Decides when the accurate lane has fallen far enough behind to be worth
/// dropping. Pure and model-free, so the policy can be tested on its own.
public struct OverloadValve: Sendable {
    /// How far behind realtime the pipeline has fallen, in seconds.
    ///
    /// This number *is* the wait the user faces: `DictationSession.stop()` drains
    /// the backlog before returning the transcript, so accumulated lag is paid
    /// after they release the key, not while they speak.
    public private(set) var debtSeconds = 0.0

    /// True once the accurate lane has been dropped for this utterance.
    public private(set) var isShedding = false

    /// The lag we are willing to hand the user after they stop speaking. Below
    /// this they notice nothing — the fast lane keeps the HUD instant either way.
    public static let defaultShedAboveSeconds = 1.5

    private let shedAbove: Double

    public init(shedAboveSeconds: Double = defaultShedAboveSeconds) {
        shedAbove = shedAboveSeconds
    }

    /// Fold one chunk's cost into the running lag.
    ///
    /// The floor at zero matters: running ahead must not bank credit, or a quiet
    /// stretch would buy the right to fall behind later and the lag would arrive
    /// somewhere unrelated to what caused it.
    public mutating func record(compute: Double, audio: Double) {
        debtSeconds = max(0, debtSeconds + compute - audio)
        if debtSeconds > shedAbove { isShedding = true }
    }
}
