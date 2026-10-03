import Foundation

/// Bounds accepted PCM (including the frame currently in inference), independently
/// of callback sizes. A generation prevents late work from releasing a new run's budget.
public final class AudioBacklog: @unchecked Sendable {
    public enum Admission: Equatable { case accepted, overloaded, closed }
    private let lock = NSLock()
    public let maximumSamples: Int
    private var generation = UUID()
    private var samples = 0
    private var accepting = false

    public init(maximumSamples: Int = 160_000) {
        precondition(maximumSamples > 0)
        self.maximumSamples = maximumSamples
    }

    @discardableResult public func reset() -> UUID {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); samples = 0; accepting = true
        return generation
    }

    public func admit(_ count: Int, generation token: UUID) -> Admission {
        lock.lock(); defer { lock.unlock() }
        guard token == generation, accepting else { return .closed }
        guard count >= 0, count <= maximumSamples - samples else {
            accepting = false
            return .overloaded
        }
        samples += count
        return .accepted
    }

    public func release(_ count: Int, generation token: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard token == generation else { return }
        samples = max(0, samples - max(0, count))
    }

    public func close(generation token: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard token == generation else { return }
        accepting = false
    }

    public var pendingSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}
