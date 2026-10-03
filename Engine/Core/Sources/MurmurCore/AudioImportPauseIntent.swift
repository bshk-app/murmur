import Foundation

/// Remembers why an import stopped, so a recording the user stopped is not
/// restarted by the phone the next time they open the app.
///
/// The reason cannot live on the job itself: a checkpoint that began before the
/// tap finishes writing afterwards and would put the old value back. It cannot be
/// a plain flag either, because leaving the app pauses the import a second time
/// and must not erase the tap that came first.
public struct AudioImportPauseIntent: Sendable {
    private var stoppedByUser = false
    public init() {}
    public mutating func paused(userInitiated: Bool) {
        if userInitiated { stoppedByUser = true }
    }
    /// Starting an import deliberately is the only thing that clears a tap.
    public mutating func started() { stoppedByUser = false }
    public var resumesAutomatically: Bool { !stoppedByUser }
}
