@testable import MurmurCore
import XCTest

final class AutomaticGainTests: XCTestCase {
    private func tone(_ amplitude: Float, seconds: Double) -> [Float] {
        (0 ..< Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    func test_quiet_speech_is_boosted_up_to_the_gain_limit() {
        var gain = AutomaticGain()
        var samples = tone(0.02, seconds: 2)
        gain.process(&samples)
        let tail = samples.suffix(16_000).map(abs).max() ?? 0
        XCTAssertEqual(tail, 0.02 * gain.maximumGain, accuracy: 0.005)
    }

    func test_loud_speech_is_never_attenuated() {
        var gain = AutomaticGain()
        let input = tone(0.5, seconds: 1)
        var samples = input
        gain.process(&samples)
        XCTAssertEqual(samples.suffix(8_000), input.suffix(8_000))
    }

    /// Instant attack: a sudden loud word after a quiet stretch cannot clip.
    func test_output_never_exceeds_the_target_or_the_input() {
        var gain = AutomaticGain()
        let input = tone(0.02, seconds: 2) + tone(0.2, seconds: 1)
        var samples = input
        gain.process(&samples)
        for (output, original) in zip(samples, input) {
            XCTAssertLessThanOrEqual(abs(output), max(gain.target, abs(original)) + 1e-6)
        }
    }

    func test_silence_stays_silent() {
        var gain = AutomaticGain()
        var samples = [Float](repeating: 0, count: 16_000)
        gain.process(&samples)
        XCTAssertEqual(samples.map(abs).max(), 0)
    }

    func test_meter_reads_speech_levels_in_decibels() {
        XCTAssertEqual(InputLevel.meter(peak: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(InputLevel.meter(peak: 0), InputLevel.floor, accuracy: 1e-6)
        // Quiet speech at -30 dBFS must be visible, not a flat line.
        XCTAssertGreaterThan(InputLevel.meter(peak: 0.03), 0.4)
        XCTAssertLessThan(InputLevel.meter(peak: 0.03), InputLevel.meter(peak: 0.3))
    }
}
