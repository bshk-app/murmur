import XCTest
import CryptoKit
import MurmurCore
@testable import MurmurTranslation

final class QualifiedAssetIntegrationTests: XCTestCase {
    private actor FetchCount {
        var count = 0
        func increment() { count += 1 }
    }
    func testMissingSelectedSharedAssetDownloadsOnceAndOfflineRequiresItsIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Transport-only fixture, deliberately not executable model weights.
        let names = ["model.bin", "config.json", "source.spm", "target.spm", "shared_vocabulary.json"]
        let data = Dictionary(uniqueKeysWithValues: names.map { ($0, Data("fixture-\($0)".utf8)) })
        func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        let files = names.map { QualityModelAsset.File(name: $0, sha256: sha(data[$0]!), bytes: data[$0]!.count) }
        let rows = files.sorted { $0.name < $1.name }.map { "\($0.name):\($0.sha256)" }
        let id = "opus-" + sha(Data(rows.joined(separator: "\n").utf8))
        let asset = try QualityModelAsset(assetID: id, directoryName: id,
            baseURL: URL(string: "https://example.test/models/resolve")!, revision: String(repeating: "a", count: 40),
            remoteDirectory: id, files: files)
        let french = TranslationModelBinding(pair: .init(source: "de", target: "fr"), modelID: id, directoryName: id, targetTag: ">>fra<<")
        let english = TranslationModelBinding(pair: .init(source: "de", target: "en"), modelID: id, directoryName: id, targetTag: ">>eng<<")
        let replacements = [french, english].map { model in
            TranslationProfile(catalogVersion: "fixture-only", request: .init(source: model.pair.source, target: model.pair.target, scenario: .text, device: .iPhone15Pro),
                models: [model], qualification: .qualified, evidenceID: "unit-test-only")
        }
        let catalog = try TranslationProfileCatalog(version: "fixture-only", bindings: Array(TranslationProfileCatalog.baseline.bindings.values),
            additionalModels: [french, english], qualifiedProfiles: replacements, enableQualifiedProfiles: true)
        let registry = try QualityModelAssetRegistry(additionalAssets: [asset])
        let service = TranslationService(modelsRoot: root, profileCatalog: catalog, scenario: .text, device: .iPhone15Pro, assetRegistry: registry)
        XCTAssertTrue(service.canPrepareQuality(from: "de", to: "fr"))
        XCTAssertTrue(TextTranslationSession.availableTargets(from: "de", modelsRoot: root, profileCatalog: catalog, assetRegistry: registry, device: .iPhone15Pro).contains("fr"))
        let old = OfflineTranslationRoutes(pairs: [.init(source: "de", target: "en"), .init(source: "en", target: "fr")], catalog: catalog, device: .iPhone15Pro)
        XCTAssertFalse(old.targets(from: "de").contains("fr"), "An old route is not proof that selected new weights are installed")
        let counter = FetchCount()
        let fetch: TranslationDownloader.Fetch = { url, progress in
            await counter.increment()
            XCTAssertTrue(url.path.contains(String(repeating: "a", count: 40)))
            let bytes = try XCTUnwrap(data[url.lastPathComponent])
            progress(Int64(bytes.count)); return bytes
        }
        try await service.prepareQuality(from: "de", to: "fr", fetcher: fetch)
        try await service.prepareQuality(from: "de", to: "en", fetcher: fetch)
        let fetched = await counter.count
        XCTAssertEqual(fetched, names.count)
        XCTAssertTrue(service.hasQualityModel(for: french))
        XCTAssertTrue(service.hasQualityModel(for: english))
        XCTAssertTrue(service.hasQualityModel(for: french.pair))
        let installed = OfflineTranslationRoutes(installedModels: [french, english], catalog: catalog, device: .iPhone15Pro)
        XCTAssertEqual(installed.targets(from: "de"), ["en", "fr"])
        XCTAssertTrue(service.usesQualityDirectory(id, from: "de", to: "fr"))
        // Same complete filenames are not proof of identity. Atomic corruption
        // invalidates cached readiness and preparation repairs it transactionally.
        let modelFile = root.appendingPathComponent(id).appendingPathComponent("model.bin")
        try Data(repeating: 0, count: data["model.bin"]!.count).write(to: modelFile, options: .atomic)
        XCTAssertFalse(service.hasQualityModel(for: french))
        XCTAssertEqual(service.pendingQualityDownloadBytes(from: "de", to: "fr"), asset.totalBytes)
        try await service.prepareQuality(from: "de", to: "fr", fetcher: fetch)
        XCTAssertTrue(service.hasQualityModel(for: french))
        let repairedCount = await counter.count
        XCTAssertEqual(repairedCount, names.count * 2)
        let storageService = TranslationService(modelsRoot: root, profileCatalog: catalog, scenario: .dictation, device: .iPhone15Pro, assetRegistry: registry)
        XCTAssertFalse(storageService.usesQualityDirectory(id, from: "de", to: "en"))
        XCTAssertTrue(storageService.usesQualityDirectoryInAnyScenario(id, from: "de", to: "en"))
        let sharedItem = ModelStorageItem(id: id, kind: .translationQuality, title: "test", detail: "test", bytes: 1)
        let removed = LanguageDownloadRemoval.translation([sharedItem], removing: french.pair, remaining: [english.pair]) { _, pair in
            storageService.usesQualityDirectoryInAnyScenario(id, from: pair.source, to: pair.target)
        }
        XCTAssertTrue(removed.isEmpty, "A remaining text-only direction still owns this shared asset")

    }
}
