import XCTest
@testable import MurmurTranslation

final class TranslationModelIdentityTests: XCTestCase {
    func testIdentityIncludesFullReadChunksAndFinalPartialChunk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var weights = Data(repeating: 0xa5, count: 2 * 1_048_576 + 37)
        weights[weights.count - 1] = 0x5a
        try weights.write(to: root.appendingPathComponent("model.bin"))
        for name in ["config.json", "source.spm", "target.spm", "shared_vocabulary.json"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        XCTAssertEqual(try TranslationModelIdentity.compute(directory: root),
                       "opus-21cd6e0a97192b593509cfa96cfde40db23624dc4a8d84489c877562a35e3f76")
    }

    func testIdentityCoversWeightsAndVocabularyButNotDirectionTag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["model.bin", "config.json", "source.spm", "target.spm", "shared_vocabulary.json"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        let original = try TranslationModelIdentity.compute(directory: root)
        try Data(">>rus<<".utf8).write(to: root.appendingPathComponent("target_tag.txt"))
        XCTAssertEqual(original, try TranslationModelIdentity.compute(directory: root))
        try Data(">>ukr<<".utf8).write(to: root.appendingPathComponent("target_tag.txt"))
        XCTAssertEqual(original, try TranslationModelIdentity.compute(directory: root))
        try Data("changed".utf8).write(to: root.appendingPathComponent("shared_vocabulary.json"))
        XCTAssertNotEqual(original, try TranslationModelIdentity.compute(directory: root))
    }

    func testCachedIdentityInvalidatesOnAtomicReplacementAndMissingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["model.bin", "config.json", "source.spm", "target.spm", "shared_vocabulary.json"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        let original = try TranslationModelIdentity.cached(directory: root)
        XCTAssertEqual(original, try TranslationModelIdentity.cached(directory: root))
        try Data(repeating: 0, count: "model.bin".utf8.count).write(to: root.appendingPathComponent("model.bin"), options: .atomic)
        XCTAssertNotEqual(original, try TranslationModelIdentity.cached(directory: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("source.spm"))
        XCTAssertThrowsError(try TranslationModelIdentity.cached(directory: root))
    }

    func testMissingVocabularyIsNotACompleteIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["model.bin", "config.json", "source.spm", "target.spm"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        XCTAssertThrowsError(try TranslationModelIdentity.compute(directory: root))
    }
}
