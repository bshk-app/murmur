import XCTest
import AVFoundation
@testable import MurmurSpeech
import MurmurCore

final class AudioFileTranscriberTests: XCTestCase {
    private func makeAudio(seconds: Int, rate: Double = 16_000, channels: AVAudioChannelCount = 1, aac: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(aac ? "m4a" : "wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let settings: [String: Any] = aac ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 64_000] : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][i] = 0.2 * sin(Float(i)*2*Float.pi*440/Float(rate)) }
        }
        for _ in 0..<seconds { try file.write(from: buffer) }
        return url
    }
    func testCompressedStereoRecordingIsDecodedAndResampledInBoundedBlocks() throws {
        let file = try makeAudio(seconds: 3, rate: 48_000, channels: 2, aac: true)
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = try AudioFilePCMReader(url: file)
        var total = 0, peak: Float = 0
        while let frame = try reader.next() {
            XCTAssertLessThanOrEqual(frame.count, 4_096)
            total += frame.count; peak = max(peak, frame.map(abs).max() ?? 0)
        }
        XCTAssertEqual(Double(total)/16_000, 3, accuracy: 0.1)
        XCTAssertGreaterThan(peak, 0.1)
    }
    func testHourFileUsesSerialTwentySecondBatchesAndResumesAtCommittedBoundary() async throws {
        let file = try makeAudio(seconds: 3_600)
        defer { try? FileManager.default.removeItem(at: file) }
        var committed: [AudioFileSegment] = [], calls = 0
        do {
            try await AudioFileTranscriber.process(reader: AudioFilePCMReader(url: file), maximumSamples: 320_000, classify: { _ in true }, transcribe: { audio in
                calls += 1
                XCTAssertLessThanOrEqual(audio.count, 320_000)
                if calls == 3 { throw CancellationError() }
                return "part"
            }, onSegment: { segment, _ in committed.append(segment) })
            XCTFail("Injected cancellation must stop processing")
        } catch is CancellationError {}
        XCTAssertEqual(committed.count, 2)
        let checkpoint = try XCTUnwrap(committed.last?.endSample)
        var nextStart = checkpoint, resumedCalls = 0
        try await AudioFileTranscriber.process(reader: AudioFilePCMReader(url: file), completedThrough: checkpoint, maximumSamples: 320_000,
            classify: { _ in true }, transcribe: { audio in
                resumedCalls += 1; XCTAssertLessThanOrEqual(audio.count, 320_000); return "part"
            }, onSegment: { segment, _ in
                XCTAssertEqual(segment.startSample, nextStart)
                nextStart = segment.endSample
            })
        XCTAssertEqual(nextStart, 3_600*16_000)
        XCTAssertGreaterThan(resumedCalls, 170)
    }
    func testNonSpeechVerdictsDoNotCallTheRecognizer() async throws {
        let file = try makeAudio(seconds: 4)
        defer { try? FileManager.default.removeItem(at: file) }
        try await AudioFileTranscriber.process(reader: AudioFilePCMReader(url: file), classify: { _ in false },
            transcribe: { _ in XCTFail("Silence must not reach ASR"); return "" }, onSegment: { _, _ in XCTFail("No speech segment expected") })
    }
    func testCanceledInferenceDoesNotCommitItsResult() async throws {
        let file = try makeAudio(seconds: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let task = Task {
            do {
                try await AudioFileTranscriber.process(reader: AudioFilePCMReader(url: file), classify: { _ in true }, transcribe: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return "late result"
                }, onSegment: { _, _ in XCTFail("Canceled recognition must not commit") })
                XCTFail("Cancellation must propagate")
            } catch is CancellationError {}
        }
        try await task.value
    }
    func testRealVoiceFileUsesVADAndTheAccurateRecognizer() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["MURMUR_AUDIO_FILE_FIXTURE"] else { throw XCTSkip("Explicit voice fixture required") }
        let engine = AudioFileTranscriber(choice: .gigaam, modelsRoot: FileManager.default.temporaryDirectory)
        actor Results {
            var segments: [AudioFileSegment] = []
            func add(_ value: AudioFileSegment) { segments.append(value) }
            var text: String { segments.map(\.text).joined(separator: " ") }
        }
        let results = Results()
        do {
            try await engine.run(url: URL(fileURLWithPath: fixture), language: "ru", onProgress: { _, _ in }, onSegment: { value, _ in await results.add(value) })
            let text = await results.text
            XCTAssertGreaterThan(text.count, 10)
            print("REAL_AUDIO_FILE_TRANSCRIPT: " + text)
        } catch { await engine.close(); throw error }
        await engine.close()
    }
    func testInvalidInputFailsBeforeLoadingARecognizer() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not audio".utf8).write(to: file)
        XCTAssertThrowsError(try AudioFilePCMReader(url: file))
    }
}
