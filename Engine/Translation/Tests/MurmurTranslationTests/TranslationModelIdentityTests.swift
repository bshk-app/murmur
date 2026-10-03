import XCTest
@testable import MurmurTranslation

@MainActor private final class ProgressLog { var values: [Double] = [] }

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

    @MainActor func testWarmReportsProgressByWeightBytesAndSkipsMissingPacks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let small = try pack(in: root, "small", weights: 1_048_576)
        let large = try pack(in: root, "large", weights: 3 * 1_048_576)
        let progress = ProgressLog()
        await TranslationModelIdentity.warm([small, root.appendingPathComponent("missing"), large]) { progress.values.append($0) }
        XCTAssertEqual(progress.values, [0.25, 1])
    }

    @MainActor func testWarmFillsTheCacheUsedByLaterChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try pack(in: root, "pack", weights: 64)
        let weights = directory.appendingPathComponent("model.bin")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: weights.path)
        let signature = try TranslationModelIdentity.fileSignature(directory: directory)
        let warmed = try TranslationModelIdentity.compute(directory: directory)
        await TranslationModelIdentity.warm([directory]) { _ in }
        // Same inode, size and mtime: only a cache hit can still report the warmed identity.
        let handle = try FileHandle(forWritingTo: weights)
        try handle.write(contentsOf: Data(repeating: 0x5a, count: 64)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: weights.path)
        XCTAssertEqual(try TranslationModelIdentity.fileSignature(directory: directory), signature)
        XCTAssertNotEqual(try TranslationModelIdentity.compute(directory: directory), warmed)
        XCTAssertEqual(try TranslationModelIdentity.cached(directory: directory), warmed)
    }

    @MainActor func testCancelledWarmStopsBeforeHashing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try pack(in: root, "pack", weights: 64)
        let progress = ProgressLog()
        let warming = Task { await TranslationModelIdentity.warm([directory]) { progress.values.append($0) } }
        warming.cancel()
        await warming.value
        XCTAssertEqual(progress.values, [])
    }

    private func pack(in root: URL, _ name: String, weights: Int) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0xa5, count: weights).write(to: directory.appendingPathComponent("model.bin"))
        for file in ["config.json", "source.spm", "target.spm", "shared_vocabulary.json"] {
            try Data(file.utf8).write(to: directory.appendingPathComponent(file))
        }
        return directory
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
