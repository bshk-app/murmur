import Foundation

/// Thread-safe bridge from microphone chunks to a single async batch consumer.
/// Capacity is measured in 4096-sample frames (default: 2 MiB of Float PCM).
/// Overflow fails explicitly; callers should persist captured audio before yield
/// if they need to recover after inference falls behind real-time capture.
public final class PCMFrameStream: @unchecked Sendable {
    public enum StreamError: Error, Equatable {
        case bufferOverflow
        case alreadyFinished
        case concurrentReader
    }

    private let lock = NSLock()
    private let maximumSamples: Int
    private var buffer: [Float] = []
    private var ended = false
    private var failure: Error?
    private var waiter: CheckedContinuation<[Float]?, Error>?

    public init(capacity: Int = 128) {
        precondition(capacity > 0 && capacity <= Int.max / AudioFileBatcher.frameSamples)
        maximumSamples = capacity * AudioFileBatcher.frameSamples
    }

    public var bufferedSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    /// No capture chunk is silently dropped. An overflow terminates the stream
    /// and discards queued inference input; future reads report the same error.
    public func yield(_ samples: [Float]) throws {
        lock.lock()
        if let failure { lock.unlock(); throw failure }
        guard !ended else { lock.unlock(); throw StreamError.alreadyFinished }
        guard samples.count <= maximumSamples - buffer.count else {
            let pending = failLocked(StreamError.bufferOverflow)
            lock.unlock()
            pending?.resume(throwing: StreamError.bufferOverflow)
            throw StreamError.bufferOverflow
        }
        buffer.append(contentsOf: samples)
        let pending = buffer.count >= AudioFileBatcher.frameSamples ? waiter : nil
        let frame = pending == nil ? nil : takeFrameLocked()
        if pending != nil { waiter = nil }
        lock.unlock()
        if let pending { pending.resume(returning: frame) }
    }

    /// Successful EOF drains buffered audio, including exactly one short tail.
    /// Failure aborts queued work immediately and wakes a suspended reader.
    public func finish(throwing error: Error? = nil) {
        lock.lock()
        guard failure == nil, !ended || error != nil else { lock.unlock(); return }
        if let error {
            let pending = failLocked(error)
            lock.unlock()
            pending?.resume(throwing: error)
        } else {
            ended = true
            let pending = waiter
            waiter = nil
            let frame = pending == nil ? nil : takeFrameLocked()
            lock.unlock()
            if let pending { pending.resume(returning: frame) }
        }
    }

    /// Exactly one consumer may await this method at a time. Cancellation ends
    /// the stream, so it also wakes a reader suspended while capture is idle.
    public func nextFrame() async throws -> [Float]? {
        let frame: [Float]? = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                read(continuation)
            }
        }, onCancel: {
            self.finish(throwing: CancellationError())
        })
        try Task.checkCancellation()
        return frame
    }

    private func read(_ continuation: CheckedContinuation<[Float]?, Error>) {
        lock.lock()
        if let failure { lock.unlock(); continuation.resume(throwing: failure); return }
        guard waiter == nil else {
            lock.unlock(); continuation.resume(throwing: StreamError.concurrentReader); return
        }
        if buffer.count >= AudioFileBatcher.frameSamples || ended {
            let frame = takeFrameLocked()
            lock.unlock()
            continuation.resume(returning: frame)
        } else {
            waiter = continuation
            lock.unlock()
        }
    }

    private func takeFrameLocked() -> [Float]? {
        guard !buffer.isEmpty else { return nil }
        let count = min(buffer.count, AudioFileBatcher.frameSamples)
        let frame = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        return frame
    }

    private func failLocked(_ error: Error) -> CheckedContinuation<[Float]?, Error>? {
        failure = error
        ended = true
        buffer.removeAll(keepingCapacity: false)
        let pending = waiter
        waiter = nil
        return pending
    }
}
