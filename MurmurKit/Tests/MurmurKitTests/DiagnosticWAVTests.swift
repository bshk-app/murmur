import XCTest
@testable import MurmurKit

final class DiagnosticWAVTests: XCTestCase {
    func test_encodes_16khz_mono_pcm() {
        let data = DiagnosticWAV.data(samples: [-1, 1])

        XCTAssertEqual(data.subdata(in: 0 ..< 4), Data("RIFF".utf8))
        XCTAssertEqual(data.subdata(in: 8 ..< 12), Data("WAVE".utf8))
        XCTAssertEqual(data.subdata(in: 36 ..< 40), Data("data".utf8))
        XCTAssertEqual(Array(data[22 ..< 24]), [1, 0]) // mono
        XCTAssertEqual(Array(data[24 ..< 28]), [0x80, 0x3E, 0, 0]) // 16 kHz
        XCTAssertEqual(Array(data[34 ..< 36]), [16, 0]) // 16-bit PCM
        XCTAssertEqual(Array(data[44 ..< 48]), [1, 0x80, 0xFF, 0x7F])
        XCTAssertEqual(data.count, 48) // 44-byte header + two Int16 samples
    }
}
