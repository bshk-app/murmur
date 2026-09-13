import XCTest
@testable import MurmurCore

final class AudioBatchProcessorTests: XCTestCase {
    func testCanaryWindowContinuousSpeechHasExactCoverageAndSerialBackpressure() async throws {
        let total = 65 * 16_000 + 137
        var read = 0, end = 0, batches = 0, recognizing = false
        try await AudioBatchProcessor.process(maximumSamples: 240_000, nextFrame: {
            XCTAssertFalse(recognizing)
            guard read < total else { return nil }
            let count = min(4096, total - read)
            let frame = (read..<read + count).map(Float.init)
            read += count
            return frame
        }, classify: { frame in
            XCTAssertEqual(frame.count, 4096)
            return true
        }, onBatch: { batch in
            recognizing = true
            let readAtStart = read
            await Task.yield()
            XCTAssertEqual(read, readAtStart)
            XCTAssertEqual(batch.range.lowerBound, end)
            XCTAssertLessThanOrEqual(batch.samples.count, 240_000)
            XCTAssertEqual(batch.samples, batch.range.map(Float.init))
            end = batch.range.upperBound
            batches += 1
            recognizing = false
        })
        XCTAssertEqual(end, total)
        XCTAssertGreaterThan(batches, 4)
    }

    func testSilenceNeverInvokesInference() async throws {
        var remaining = 200
        try await AudioBatchProcessor.process(maximumSamples: 240_000, nextFrame: {
            guard remaining > 0 else { return nil }
            remaining -= 1
            return Array(repeating: 0, count: 4096)
        }, classify: { _ in false }, onBatch: { _ in XCTFail("Silence must not reach inference") })
    }

    func testCancellationStopsBeforeAnotherFrameIsRead() async throws {
        let task = Task {
            var read = 0
            do {
                try await AudioBatchProcessor.process(maximumSamples: 240_000, nextFrame: {
                    read += 1
                    return Array(repeating: 1, count: 4096)
                }, classify: { _ in true }, onBatch: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                })
                XCTFail("Cancellation must propagate")
            } catch is CancellationError {
                XCTAssertEqual(read, 58)
            }
        }
        try await task.value
    }

    func testResumeSkipsOnlyCommittedWindowsAndRejectsPartialBoundary() async throws {
        func run(checkpoint: Int, output: (AudioFileBatch) -> Void) async throws {
            var read = 0
            try await AudioBatchProcessor.process(maximumSamples: 240_000, completedThrough: checkpoint, nextFrame: {
                guard read < 100 else { return nil }
                read += 1
                return Array(repeating: 1, count: 4096)
            }, classify: { _ in true }, onBatch: { output($0) })
        }
        var initial: [Range<Int>] = [], resumed: [Range<Int>] = []
        try await run(checkpoint: 0) { initial.append($0.range) }
        try await run(checkpoint: initial[0].upperBound) { resumed.append($0.range) }
        XCTAssertEqual(resumed, Array(initial.dropFirst()))
        do {
            try await run(checkpoint: 1) { _ in XCTFail("Invalid boundary must not be emitted") }
            XCTFail("Expected invalid resume boundary")
        } catch let error as AudioBatchProcessor.InputError {
            XCTAssertEqual(error, .invalidResumeBoundary)
        }
    }

    func testCancellationDuringClassificationDoesNotEmitLateBatch() async throws {
        let task = Task {
            do {
                try await AudioBatchProcessor.process(nextFrame: { [1, 2, 3] }, classify: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    await Task.yield()
                    return true
                }, onBatch: { _ in XCTFail("Canceled classifier must not emit a tail") })
                XCTFail("Cancellation must propagate")
            } catch is CancellationError {}
        }
        try await task.value
    }

    func testNonFinalPartialFrameIsRejectedInsteadOfMisaligningRanges() async throws {
        var count = 0
        do {
            try await AudioBatchProcessor.process(nextFrame: {
                count += 1
                return count <= 2 ? [1, 2, 3] : nil
            }, classify: { _ in true }, onBatch: { _ in })
            XCTFail("Expected malformed frame stream")
        } catch let error as AudioBatchProcessor.InputError {
            XCTAssertEqual(error, .frameAfterTail)
        }
    }
}
