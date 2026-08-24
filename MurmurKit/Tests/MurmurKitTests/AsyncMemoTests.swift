import XCTest
@testable import MurmurKit

private actor LoadProbe {
    private(set) var calls = 0
    private var shouldFail = false

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func load() async throws -> Int {
        calls += 1
        // Hold the task open so every concurrent caller reaches the memo while it
        // is in flight; without memoization each would increment `calls`.
        try await Task.sleep(nanoseconds: 20_000_000)
        if shouldFail {
            shouldFail = false
            throw NSError(domain: "test", code: 1)
        }
        return 42
    }
}

final class AsyncMemoTests: XCTestCase {
    /// Concurrent GUI preparation (bootstrap + reopened Setup Tour) must share one
    /// multi-GB model load rather than both observing nil and downloading/loading.
    func test_concurrent_callers_share_one_in_flight_load() async throws {
        let memo = AsyncMemo<Int>()
        let probe = LoadProbe()

        async let first = memo.get { try await probe.load() }
        async let second = memo.get { try await probe.load() }
        async let third = memo.get { try await probe.load() }

        let values = try await [first, second, third]
        XCTAssertEqual(values, [42, 42, 42])
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(memo.cached, 42)
    }

    /// A failed first download must not poison the memo forever; the existing UI
    /// exposes Retry and expects the next call to perform a fresh load.
    func test_failure_clears_the_in_flight_task_for_retry() async throws {
        let memo = AsyncMemo<Int>()
        let probe = LoadProbe(shouldFail: true)

        do {
            _ = try await memo.get { try await probe.load() }
            XCTFail("the first load should fail")
        } catch {
            // expected
        }

        let value = try await memo.get { try await probe.load() }
        XCTAssertEqual(value, 42)
        let calls = await probe.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(memo.cached, 42)
    }
}
