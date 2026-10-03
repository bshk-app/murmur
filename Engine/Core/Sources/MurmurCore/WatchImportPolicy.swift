import Foundation

/// Picks one Apple Watch recording to transcribe without the user asking. Unlike a
/// file the user hands over deliberately, a watch recording arrives while the phone
/// may be locked, busy or out of memory, so every condition that would make the
/// existing import controller refuse is decided here instead of attempted blindly.
/// Call again after acting: the next recording joins the queue of the one that started.
public enum WatchImportPolicy {
    public struct Candidate: Sendable {
        public let id: UUID
        public let createdAt: Date
        public let queued: Bool
        public let autoStart: Bool
        public let prepared: Bool
        public init(id: UUID, createdAt: Date, queued: Bool, autoStart: Bool, prepared: Bool) {
            self.id = id; self.createdAt = createdAt; self.queued = queued
            self.autoStart = autoStart; self.prepared = prepared
        }
    }
    /// Recordings are transcribed in the order they were spoken. Starting from idle
    /// unloads the warm models, so it waits until that is allowed; joining a running
    /// import costs nothing and only happens once per recording.
    public static func next(activeID: UUID?, receiving: Bool, foreground: Bool, keyboardActive: Bool,
                            memoryReleasable: Bool, candidates: [Candidate]) -> UUID? {
        guard foreground, !receiving, !keyboardActive, activeID != nil || memoryReleasable else { return nil }
        return candidates
            .filter { $0.autoStart && $0.prepared && $0.id != activeID && (activeID == nil || !$0.queued) }
            .min { $0.createdAt < $1.createdAt }?.id
    }

    /// Whether to offer notifications for arriving recordings. Asking before a
    /// watch is involved would be noise, and the background cannot ask at all.
    /// A recording that already arrived counts on its own: a watch app installed
    /// outside the phone's Watch app never reports itself as installed, and
    /// without this the offer would never be made and every arrival would pass
    /// silently.
    public static func shouldAskAboutNotifications(watchAppInstalled: Bool, hasRecordings: Bool,
                                                   foreground: Bool, undecided: Bool) -> Bool {
        (watchAppInstalled || hasRecordings) && foreground && undecided
    }
}
