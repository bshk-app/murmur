import XCTest
@testable import MurmurCore

final class PCMFrameStreamTests: XCTestCase {
    func testMicrophoneChunksCoalesceInOrderAndEOFTailAppearsOnce() async throws {
        let stream = PCMFrameStream(capacity: 16)
        let original = (0..<32_137).map(Float.init)
        for start in stride(from: 0, to: original.count, by: 1536) {
            try stream.yield(Array(original[start..<min(start + 1536, original.count)]))
        }
        stream.finish()
        var output: [Float] = [], sizes: [Int] = []
        while let frame = try await stream.nextFrame() {
            sizes.append(frame.count)
            output.append(contentsOf: frame)
        }
        XCTAssertEqual(output, original)
        XCTAssertEqual(sizes, Array(repeating: 4096, count: 7) + [3465])
        let eof = try await stream.nextFrame()
        XCTAssertNil(eof)
        XCTAssertEqual(stream.bufferedSamples, 0)
    }

    func testOverflowFailsBothProducerAndConsumerInsteadOfDroppingAudio() async throws {
        let stream = PCMFrameStream(capacity: 1)
        try stream.yield(Array(repeating: 1, count: 4096))
        XCTAssertEqual(stream.bufferedSamples, 4096)
        XCTAssertThrowsError(try stream.yield([2])) { error in
            XCTAssertEqual(error as? PCMFrameStream.StreamError, .bufferOverflow)
        }
        XCTAssertEqual(stream.bufferedSamples, 0)
        do {
            _ = try await stream.nextFrame()
            XCTFail("Consumer must learn about lost capacity")
        } catch let error as PCMFrameStream.StreamError {
            XCTAssertEqual(error, .bufferOverflow)
        }
    }

    func testReadReleasesCapacityForTheNextCaptureChunk() async throws {
        let stream = PCMFrameStream(capacity: 1)
        try stream.yield(Array(repeating: 1, count: 4096))
        let first = try await stream.nextFrame()
        XCTAssertEqual(first?.count, 4096)
        try stream.yield([2, 3])
        stream.finish()
        let tail = try await stream.nextFrame()
        XCTAssertEqual(tail, [2, 3])
    }

    func testIdleConsumerCancellationUnblocksAndTerminatesStream() async throws {
        let stream = PCMFrameStream()
        let started = expectation(description: "consumer starts")
        let task = Task {
            started.fulfill()
            do {
                _ = try await stream.nextFrame()
                XCTFail("Canceled reader must throw")
            } catch is CancellationError {}
        }
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<10 { await Task.yield() }
        task.cancel()
        try await task.value
        XCTAssertThrowsError(try stream.yield([1])) { XCTAssertTrue($0 is CancellationError) }
    }

    func testFailureWakesIdleConsumer() async throws {
        let stream = PCMFrameStream()
        let started = expectation(description: "consumer starts")
        let task = Task {
            started.fulfill()
            do {
                _ = try await stream.nextFrame()
                XCTFail("Failed reader must throw")
            } catch let error as PCMFrameStream.StreamError {
                XCTAssertEqual(error, .bufferOverflow)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        stream.finish(throwing: PCMFrameStream.StreamError.bufferOverflow)
        try await task.value
    }

    func testAlreadyCanceledConsumerTerminatesStreamWithoutSuspending() async throws {
        let stream = PCMFrameStream()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await stream.nextFrame()
                XCTFail("Canceled task must not start reading")
            } catch is CancellationError {}
        }
        try await task.value
        XCTAssertThrowsError(try stream.yield([1])) { XCTAssertTrue($0 is CancellationError) }
    }

    func testSuccessfulEOFWakesReaderWithShortTail() async throws {
        let stream = PCMFrameStream()
        try stream.yield([1, 2, 3])
        let started = expectation(description: "consumer starts")
        let task = Task { () throws -> [Float]? in
            started.fulfill()
            return try await stream.nextFrame()
        }
        await fulfillment(of: [started], timeout: 2)
        stream.finish()
        let tail = try await task.value
        XCTAssertEqual(tail, [1, 2, 3])
        let eof = try await stream.nextFrame()
        XCTAssertNil(eof)
        XCTAssertThrowsError(try stream.yield([4])) { error in
            XCTAssertEqual(error as? PCMFrameStream.StreamError, .alreadyFinished)
        }
    }

    func testStreamFeedsBatchProcessorWithoutRangeGaps() async throws {
        let stream = PCMFrameStream()
        let total = 32 * 16_000 + 137
        let producer = Task {
            for start in stride(from: 0, to: total, by: 1536) {
                try stream.yield((start..<min(start + 1536, total)).map(Float.init))
                await Task.yield()
            }
            stream.finish()
        }
        var end = 0
        try await AudioBatchProcessor.process(maximumSamples: 240_000, nextFrame: { try await stream.nextFrame() },
            classify: { _ in true }, onBatch: { batch in
                XCTAssertEqual(batch.range.lowerBound, end)
                XCTAssertEqual(batch.samples, batch.range.map(Float.init))
                XCTAssertLessThanOrEqual(batch.samples.count, 240_000)
                end = batch.range.upperBound
            })
        try await producer.value
        XCTAssertEqual(end, total)
    }
}
