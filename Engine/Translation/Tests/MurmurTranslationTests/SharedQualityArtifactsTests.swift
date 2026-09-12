import XCTest
import CryptoKit
@testable import MurmurTranslation

final class SharedQualityArtifactsTests: XCTestCase {
    func testVerifiedWeightsAreSharedAndSurviveRemovingEitherDirection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let bytes = Data("weights".utf8), file = a.appendingPathComponent("model.bin")
        try bytes.write(to: file)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let found = try XCTUnwrap(SharedQualityArtifacts.reusableFile(name: "model.bin", sha256: sha, bytes: bytes.count, directories: [a]))
        let copy = b.appendingPathComponent("model.bin")
        try SharedQualityArtifacts.link(found, into: copy)
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(inode, try FileManager.default.attributesOfItem(atPath: copy.path)[.systemFileNumber] as? NSNumber)
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
    }

    func testCorruptOrDirectionSpecificFilesAreNeverReused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("bad".utf8)
        try bytes.write(to: root.appendingPathComponent("model.bin"))
        XCTAssertNil(try SharedQualityArtifacts.reusableFile(name: "model.bin", sha256: String(repeating: "0", count: 64), bytes: bytes.count, directories: [root]))
        try bytes.write(to: root.appendingPathComponent("target_tag.txt"))
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertNil(try SharedQualityArtifacts.reusableFile(name: "target_tag.txt", sha256: sha, bytes: bytes.count, directories: [root]))
    }

    func testPublishReplacesAtomicallyAndRetainsPreviousUntilSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("installed"), staging = root.appendingPathComponent("staging")
        for directory in [destination, staging] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("old".utf8).write(to: destination.appendingPathComponent("model"))
        try Data("new".utf8).write(to: staging.appendingPathComponent("model"))
        XCTAssertThrowsError(try SharedQualityArtifacts.publish(staging: root.appendingPathComponent("absent"), destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("model")), Data("old".utf8))
        try SharedQualityArtifacts.publish(staging: staging, destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("model")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("model")), Data("old".utf8))
    }
}
