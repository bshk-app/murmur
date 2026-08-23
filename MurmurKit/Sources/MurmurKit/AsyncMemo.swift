import Foundation

/// One async value whose concurrent callers share the same in-flight load.
/// Failed loads are forgotten so a UI Retry performs real work again.
final class AsyncMemo<Value>: @unchecked Sendable {
    private enum Acquisition {
        case cached(Value)
        case task(id: UInt64, Task<Value, Error>)
    }

    private let lock = NSLock()
    private var value: Value?
    private var inFlight: (id: UInt64, task: Task<Value, Error>)?
    private var nextID: UInt64 = 0

    var cached: Value? {
        lock.withLock { value }
    }

    func get(_ load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let acquisition: Acquisition = lock.withLock {
            if let value { return .cached(value) }
            if let inFlight { return .task(id: inFlight.id, inFlight.task) }

            nextID &+= 1
            let id = nextID
            let task = Task { try await load() }
            inFlight = (id, task)
            return .task(id: id, task)
        }

        switch acquisition {
        case let .cached(value):
            return value

        case let .task(id, task):
            do {
                let loaded = try await task.value
                lock.withLock {
                    guard inFlight?.id == id else { return }
                    value = loaded
                    inFlight = nil
                }
                return loaded
            } catch {
                lock.withLock {
                    if inFlight?.id == id { inFlight = nil }
                }
                throw error
            }
        }
    }
}
