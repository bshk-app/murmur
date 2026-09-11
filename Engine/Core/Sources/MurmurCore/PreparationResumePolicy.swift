import Foundation

public struct PreparationResumePolicy: Sendable {
    public private(set) var request: String?
    public private(set) var isPaused: Bool
    private var token: UUID?
    public init(savedRequest: String? = nil) { request = savedRequest; isPaused = savedRequest != nil }
    @discardableResult public mutating func begin(_ request: String) -> UUID {
        let next = UUID(); self.request = request; token = next; isPaused = false; return next
    }
    @discardableResult public mutating func pause() -> Bool {
        guard request != nil, !isPaused else { return false }
        isPaused = true; token = nil; return true
    }
    public mutating func complete(_ token: UUID) {
        guard self.token == token, !isPaused else { return }
        request = nil; self.token = nil
    }
    public mutating func cancel() { request = nil; token = nil; isPaused = false }
    public func resumableRequest(isActive: Bool, isBusy: Bool) -> String? {
        isActive && !isBusy && isPaused ? request : nil
    }
}

public enum PreparationProgress {
    /// Completed stages keep their share when the next file/model starts at zero.
    public static func fraction(step: Int, steps: Int, current: Double, batch: Int = 0, batches: Int = 1) -> Double {
        let within = (Double(max(0, step)) + min(1, max(0, current))) / Double(max(1, steps))
        return min(1, max(0, (Double(max(0, batch)) + within) / Double(max(1, batches))))
    }
}
