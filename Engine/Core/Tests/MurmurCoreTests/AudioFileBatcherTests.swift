import XCTest
@testable import MurmurCore

final class AudioFileBatcherTests: XCTestCase {
    func testCanaryCapIncludesSilenceAtEOF() {
        var batcher = AudioFileBatcher(maximumSamples: 240_000)
        var batches: [AudioFileBatch] = []
        for index in 0..<59 {
            if let batch = batcher.append(Array(repeating: Float(index), count: 4096), isSpeech: index < 57) {
                batches.append(batch)
            }
            XCTAssertLessThanOrEqual(batcher.bufferedSamples, 240_000)
        }
        if let batch = batcher.finish() { batches.append(batch) }
        var end = 0
        for batch in batches {
            XCTAssertLessThanOrEqual(batch.samples.count, 240_000)
            XCTAssertEqual(batch.range.lowerBound, end)
            XCTAssertEqual(batch.samples.count, batch.range.count)
            end = batch.range.upperBound
        }
        XCTAssertEqual(end, 59 * 4096)
    }
    func testSpeechRemainderAfterHardCapSurvivesFollowingPause() {
        var batcher = AudioFileBatcher(maximumSamples: 240_000)
        var ranges: [Range<Int>] = []
        for index in 0..<62 {
            let speech = index < 57 || index == 58
            if let batch = batcher.append(Array(repeating: 1, count: 4096), isSpeech: speech) {
                ranges.append(batch.range)
                XCTAssertLessThanOrEqual(batch.samples.count, 240_000)
            }
        }
        if let batch = batcher.finish() { ranges.append(batch.range) }
        XCTAssertEqual(ranges, [0..<240_000, 240_000..<(59 * 4096)])
    }
    func testHourWithoutPausesStaysBoundedAndEverySampleAppearsOnce() {
        var batcher = AudioFileBatcher()
        let total = 3_600 * 16_000 + 173
        var end = 0, count = 0, read = 0
        func check(_ batch: AudioFileBatch) {
            XCTAssertEqual(batch.range.lowerBound, end)
            XCTAssertEqual(batch.samples.count, batch.range.count)
            XCTAssertLessThanOrEqual(batch.samples.count, AudioFileBatcher.maximumBatchSamples)
            end = batch.range.upperBound; count += 1
        }
        while read < total {
            let n = min(4_096, total-read)
            if let batch = batcher.append(Array(repeating: 0.1, count: n), isSpeech: true) { check(batch) }
            read += n
            XCTAssertLessThanOrEqual(batcher.bufferedSamples, AudioFileBatcher.maximumBatchSamples + 4_096)
        }
        if let batch = batcher.finish() { check(batch) }
        XCTAssertEqual(end, total); XCTAssertGreaterThan(count, 170)
        XCTAssertEqual(batcher.bufferedSamples, 0)
    }
    func testSmallerRecognizerWindowIsHonored() {
        var batcher = AudioFileBatcher(maximumSamples: 12 * 16_000)
        var count = 0
        for _ in 0..<300 {
            if let batch = batcher.append(Array(repeating: 0.1, count: 4_096), isSpeech: true) {
                XCTAssertLessThanOrEqual(batch.samples.count, 12 * 16_000); count += 1
            }
        }
        if let batch = batcher.finish() { XCTAssertLessThanOrEqual(batch.samples.count, 12 * 16_000) }
        XCTAssertGreaterThan(count, 5)
    }
    func testSilenceDoesNotCreateRecognitionJobs() {
        var batcher = AudioFileBatcher()
        for _ in 0..<14_063 {
            XCTAssertNil(batcher.append(Array(repeating: 0, count: 4_096), isSpeech: false))
            XCTAssertLessThanOrEqual(batcher.bufferedSamples, 8_192)
        }
        XCTAssertNil(batcher.finish())
    }
    func testPausesSplitBeforeTheSafetyCapAndKeepFinalShortTail() {
        var batcher = AudioFileBatcher(), batches: [AudioFileBatch] = []
        for speech in [false, true, true, false, false, false, true] {
            if let batch = batcher.append(Array(repeating: 1, count: 4_096), isSpeech: speech) { batches.append(batch) }
        }
        _ = batcher.append(Array(repeating: 2, count: 137), isSpeech: true)
        if let tail = batcher.finish() { batches.append(tail) }
        XCTAssertEqual(batches.count, 2)
        XCTAssertLessThanOrEqual(batches[0].range.upperBound, batches[1].range.lowerBound)
        XCTAssertEqual(batches.last?.range.upperBound, 7*4_096+137)
        XCTAssertEqual(batches.last?.samples.suffix(137), Array(repeating: Float(2), count: 137)[...])
    }
}
