@testable import MurmurSpeech
import Foundation
import HuggingFace
import XCTest
@testable import MurmurKit

final class CoreMLSnapshotFilesTests: XCTestCase {
    func test_nested_package_directories_are_never_downloaded_as_files() throws {
        let json = """
        [
          {"type":"directory","path":"Decoder.mlmodelc/analytics"},
          {"type":"file","path":"Decoder.mlmodelc/analytics/coremldata.bin"},
          {"type":"directory","path":"EncoderInt4.mlmodelc/weights"},
          {"type":"file","path":"EncoderInt4.mlmodelc/weights/weight.bin"},
          {"type":"file","path":"Encoder.mlmodelc/weights/weight.bin"},
          {"type":"file","path":"Decoder.mlmodelc-backup/weights/weight.bin"},
          {"type":"file","path":"parakeet_vocab.json"}
        ]
        """
        let entries = try JSONDecoder().decode([Git.TreeEntry].self, from: Data(json.utf8))
        XCTAssertEqual(Set(CoreMLSnapshotFiles.select(from: entries, encoder: "EncoderInt4.mlmodelc")), [
            "Decoder.mlmodelc/analytics/coremldata.bin",
            "EncoderInt4.mlmodelc/weights/weight.bin",
            "parakeet_vocab.json",
        ])
    }

    func test_unrelated_manifest_does_not_select_everything() throws {
        let data = Data("[{\"type\":\"file\",\"path\":\"README.md\"}]".utf8)
        let entries = try JSONDecoder().decode([Git.TreeEntry].self, from: data)
        XCTAssertTrue(CoreMLSnapshotFiles.select(from: entries, encoder: "EncoderInt4.mlmodelc").isEmpty)
    }
}
