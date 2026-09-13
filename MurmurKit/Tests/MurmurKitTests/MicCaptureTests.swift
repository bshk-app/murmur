@testable import MurmurSpeech
import AVFoundation
import XCTest
@testable import MurmurKit

final class MicCaptureTests: XCTestCase {
    func test_capture_boundary_flushes_tail_before_closing_recording() {
        let mic = MicCapture()
        var recording = true
        var saved: [Float] = []
        mic.onChunk = { if recording { saved += $0 } }
        mic.enqueue([1])
        mic.flushPending()
        // This is the legal producer interleaving between the old flush and close.
        mic.enqueue([2])
        mic.atCaptureBoundary { recording = false }
        mic.flushPending()
        XCTAssertEqual(saved, [1, 2])
    }

    func test_capture_boundary_discards_idle_tail_before_opening_recording() {
        let mic = MicCapture()
        var recording = false
        var saved: [Float] = []
        mic.onChunk = { if recording { saved += $0 } }
        mic.flushPending()
        mic.enqueue([1])
        mic.atCaptureBoundary { recording = true }
        mic.enqueue([2])
        mic.atCaptureBoundary { recording = false }
        XCTAssertEqual(saved, [2])
    }

    func test_converter_tail_is_drained_at_stop() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
            channels: 1, interleaved: false
        ))
        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        ))
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 44_100))
        input.frameLength = 44_100
        input.floatChannelData?[0][0] = 1
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 20_000))

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        XCTAssertNil(error)

        let tail = MicCapture.drain(converter, outputFormat: outputFormat)
        XCTAssertFalse(tail.isEmpty)
        XCTAssertEqual(Int(output.frameLength) + tail.count, 16_000)
    }
}
