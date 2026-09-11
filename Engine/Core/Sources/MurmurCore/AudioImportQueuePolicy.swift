import Foundation

/// Selects one queued import only after the current worker and UI lifetime allow it.
public enum AudioImportQueuePolicy {
    public struct Waiting: Sendable {
        public let id: UUID
        public let queuedAt: Date
        public init(id: UUID, queuedAt: Date) { self.id = id; self.queuedAt = queuedAt }
    }
    public static func next(activeID: UUID?, receiving: Bool, suspended: Bool, foreground: Bool, waiting: [Waiting]) -> UUID? {
        guard activeID == nil, !receiving, !suspended, foreground else { return nil }
        return waiting.min { $0.queuedAt < $1.queuedAt }?.id
    }
}
