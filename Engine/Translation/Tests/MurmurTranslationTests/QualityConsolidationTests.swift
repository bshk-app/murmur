import XCTest
import CryptoKit
import MurmurCore
@testable import MurmurTranslation

final class QualityConsolidationTests: XCTestCase {
    func testExistingDuplicatesConsolidateDeterministicallyAndSurviveRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ["a", "b", "c"].map { root.appendingPathComponent($0) }
        let bytes = Data("matching weights".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: directory.appendingPathComponent("model.bin"))
            try Data(directory.lastPathComponent.utf8).write(to: directory.appendingPathComponent("target_tag.txt"))
        }
        let original = try inode(directories[0])
        XCTAssertEqual(try SharedQualityArtifacts.consolidate(name: "model.bin", sha256: digest, bytes: bytes.count, directories: directories.reversed()), Int64(bytes.count * 2))
        for directory in directories { XCTAssertEqual(try inode(directory), original) }
        XCTAssertEqual(try SharedQualityArtifacts.consolidate(name: "model.bin", sha256: digest, bytes: bytes.count, directories: directories), 0)
        XCTAssertEqual(try SharedQualityArtifacts.consolidate(name: "target_tag.txt", sha256: digest, bytes: bytes.count, directories: directories), 0)
        try FileManager.default.removeItem(at: directories[0])
        for directory in directories.dropFirst() {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("model.bin")), bytes)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("target_tag.txt")), Data(directory.lastPathComponent.utf8))
        }
    }
    func testCorruptLexicallyFirstPeerSkipped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ["a", "b", "c"].map { root.appendingPathComponent($0) }
        for directory in directories { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("bad".utf8).write(to: directories[0].appendingPathComponent("model.bin"))
        for directory in directories.dropFirst() { try Data("yes".utf8).write(to: directory.appendingPathComponent("model.bin")) }
        let digest = SHA256.hash(data: Data("yes".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try SharedQualityArtifacts.consolidate(name: "model.bin", sha256: digest, bytes: 3, directories: directories), 3)
        XCTAssertEqual(try Data(contentsOf: directories[0].appendingPathComponent("model.bin")), Data("bad".utf8))
        XCTAssertEqual(try inode(directories[1]), try inode(directories[2]))
    }
    func testBusyStoreCannotConsolidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try ModelFileAccess.enable(in: root)
        let reader = try ModelFileAccess.acquire(in: root, writing: false)
        defer { withExtendedLifetime(reader) {} }
        XCTAssertThrowsError(try TranslationDownloader.consolidateQualityArtifacts(for: .init(source: "en", target: "ru"), in: root)) { XCTAssertTrue($0 is ModelFileAccess.Busy) }
    }
    private func inode(_ directory: URL) throws -> NSNumber {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("model.bin").path)[.systemFileNumber] as? NSNumber)
    }
}
