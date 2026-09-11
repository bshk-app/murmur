import XCTest
@testable import MurmurCore

final class LanguageDownloadRemovalTests: XCTestCase {
    func testRemovingRussianKeepsSharedFinnishDownloadAndRecordedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = ["speech/russian-accurate", "speech/multilingual-accurate", "speech/detection-live"].enumerated().map { index, id in
            ModelStorageLocation(id: id, root: root, directory: root.appendingPathComponent("model-\(index)"), title: id, detail: "")
        }
        for item in locations {
            try FileManager.default.createDirectory(at: item.directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: item.directory.appendingPathComponent("weights.bin"))
        }
        let audio = root.appendingPathComponent("recording.wav"); try Data([5, 6, 7]).write(to: audio)
        let storage = ModelStorage(modelsRoot: root.appendingPathComponent("Models"), speech: locations, translationRoot: root.appendingPathComponent("Translations"))
        let inventory = try await storage.inventory()
        let deleted = LanguageDownloadRemoval.speech(inventory.items, removing: "ru", remaining: ["fi"])
        XCTAssertEqual(deleted.map(\.id), ["speech/russian-accurate"])
        for item in deleted { try await storage.remove(id: item.id) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations[0].directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations[1].directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations[2].directory.path))
        XCTAssertEqual(try Data(contentsOf: audio), Data([5, 6, 7]))
        let after = try await storage.inventory()
        XCTAssertEqual(Set(LanguageDownloadRemoval.speech(after.items, removing: "fi", remaining: []).map(\.id)), Set(["speech/multilingual-accurate", "speech/detection-live"]))
    }
    func testRemovingTranslationKeepsEnglishPivotUsedByAnotherPair() {
        let pairs = [LanguagePair(source: "fi", target: "en"), .init(source: "de", target: "en"), .init(source: "en", target: "ru")]
        let items = pairs.map { pair in ModelStorageItem(id: pair.source + pair.target, kind: .translationQuality, title: "", detail: "", source: pair.source, target: pair.target, bytes: 10) }
        let removing = LanguagePair(source: "fi", target: "ru"), remaining = LanguagePair(source: "de", target: "ru")
        let result = LanguageDownloadRemoval.translation(items, removing: removing, remaining: [remaining]) { item, pair in
            (item.source == pair.source && item.target == "en") || (item.source == "en" && item.target == pair.target)
        }
        XCTAssertEqual(result.map(\.id), ["fien"])
    }
}
