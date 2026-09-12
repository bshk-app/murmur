import XCTest
import CryptoKit
import MurmurCore
@testable import MurmurTranslation

private actor AssetFetchCounter {
    var count = 0
    func fetched() { count += 1 }
}
final class QualityModelAssetTests: XCTestCase {
    private func fixture() throws -> (URL, QualityModelAsset, [String: Data]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ModelFileAccess.enable(in: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let payloads = Dictionary(uniqueKeysWithValues: ["model.bin", "config.json", "source.spm", "target.spm", "shared_vocabulary.json"].map { ($0, Data(("test-only-" + $0).utf8)) })
        for (name, bytes) in payloads { try bytes.write(to: source.appendingPathComponent(name)) }
        let identity = try TranslationModelIdentity.compute(directory: source)
        let files = payloads.map { name, bytes in QualityModelAsset.File(name: name,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), bytes: bytes.count) }
        return (root, try QualityModelAsset(assetID: identity, directoryName: identity,
            baseURL: URL(string: "https://example.com/models/resolve")!, revision: String(repeating: "a", count: 40),
            remoteDirectory: "shared", files: files), payloads)
    }
    func testSharedDirectoryInstallsOnceAndRegistryMatchesBothBindings() async throws {
        let (root, asset, payloads) = try fixture()
        let registry = try QualityModelAssetRegistry(additionalAssets: [asset])
        let first = TranslationModelBinding(pair: .init(source: "en", target: "da"), modelID: asset.assetID, directoryName: asset.directoryName, targetTag: ">>dan<<")
        let second = TranslationModelBinding(pair: .init(source: "en", target: "sv"), modelID: asset.assetID, directoryName: asset.directoryName, targetTag: ">>swe<<")
        XCTAssertNotNil(registry.asset(for: first)); XCTAssertNotNil(registry.asset(for: second))
        let counter = AssetFetchCounter()
        let fetch: TranslationDownloader.Fetch = { url, _ in
            XCTAssertTrue(url.absoluteString.contains(String(repeating: "a", count: 40) + "/shared/"))
            await counter.fetched()
            return try XCTUnwrap(payloads[url.lastPathComponent])
        }
        let installed = try await TranslationDownloader.download(binding: first, asset: asset, into: root, fetcher: fetch, freeSpace: { _ in 100_000_000 })
        let again = try await TranslationDownloader.download(binding: second, asset: asset, into: root, fetcher: fetch, freeSpace: { _ in 100_000_000 })
        XCTAssertEqual(installed.path, again.path)
        let count = await counter.count
        XCTAssertEqual(count, payloads.count)
        XCTAssertEqual(try TranslationModelIdentity.compute(directory: installed), asset.assetID)
    }
    func testWrongHashAndIncompleteFetchKeepPreviousDirectory() async throws {
        let (root, asset, payloads) = try fixture()
        let installed = root.appendingPathComponent(asset.directoryName)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("previous".utf8).write(to: installed.appendingPathComponent("model.bin"))
        let binding = TranslationModelBinding(pair: .init(source: "en", target: "da"), modelID: asset.assetID, directoryName: asset.directoryName)
        for missing in [false, true] {
            do {
                _ = try await TranslationDownloader.download(binding: binding, asset: asset, into: root,
                    fetcher: { url, _ in
                        if missing && url.lastPathComponent == "target.spm" { throw CocoaError(.fileReadNoSuchFile) }
                        return missing ? try XCTUnwrap(payloads[url.lastPathComponent]) : Data("bad".utf8)
                    }, freeSpace: { _ in 100_000_000 })
                XCTFail("Invalid download succeeded")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("model.bin")), Data("previous".utf8))
        }
        _ = try await TranslationDownloader.download(binding: binding, asset: asset, into: root,
            fetcher: { url, _ in try XCTUnwrap(payloads[url.lastPathComponent]) }, freeSpace: { _ in 100_000_000 })
        XCTAssertEqual(try TranslationModelIdentity.compute(directory: installed), asset.assetID)
    }
    func testAssetRejectsIncompleteManifestWrongIdentityMutableRevisionAndBinding() async throws {
        let (root, asset, _) = try fixture()
        func make(_ files: [QualityModelAsset.File], id: String, revision: String) throws -> QualityModelAsset {
            try .init(assetID: id, directoryName: asset.directoryName, baseURL: asset.baseURL, revision: revision, remoteDirectory: asset.remoteDirectory, files: files)
        }
        XCTAssertThrowsError(try make(asset.files.filter { $0.name != "target.spm" }, id: asset.assetID, revision: asset.revision))
        XCTAssertThrowsError(try make(asset.files, id: "opus-wrong", revision: asset.revision))
        XCTAssertThrowsError(try make(asset.files, id: asset.assetID, revision: "main"))
        do {
            _ = try await TranslationDownloader.download(binding: .init(pair: .init(source: "en", target: "da"), modelID: "wrong", directoryName: asset.directoryName), asset: asset, into: root,
                fetcher: { _, _ in XCTFail("Mismatched binding fetched"); return Data() })
            XCTFail("Mismatched identity accepted")
        } catch {}
    }
    func testRegistryRejectsNonContentAddressedAdditionalDirectory() throws {
        let (_, asset, _) = try fixture()
        let legacyLayout = try QualityModelAsset(assetID: asset.assetID, directoryName: "ct2-custom",
            baseURL: asset.baseURL, revision: asset.revision, remoteDirectory: asset.remoteDirectory, files: asset.files)
        XCTAssertThrowsError(try QualityModelAssetRegistry(additionalAssets: [legacyLayout]))
    }
    func testDeclaredSizeMismatchCannotPublish() async throws {
        let (root, asset, payloads) = try fixture()
        let wrongSize = try QualityModelAsset(assetID: asset.assetID, directoryName: asset.directoryName,
            baseURL: asset.baseURL, revision: asset.revision, remoteDirectory: asset.remoteDirectory,
            files: asset.files.map { .init(name: $0.name, sha256: $0.sha256, bytes: $0.bytes + 1) })
        do {
            _ = try await TranslationDownloader.download(binding: .init(pair: .init(source: "en", target: "da"), modelID: asset.assetID, directoryName: asset.directoryName),
                asset: wrongSize, into: root, fetcher: { url, _ in try XCTUnwrap(payloads[url.lastPathComponent]) }, freeSpace: { _ in 100_000_000 })
            XCTFail("Wrong size published")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.directoryName).path))
    }
    func testAllBaselineBindingsRemainRegistered() {
        for binding in TranslationProfileCatalog.baseline.bindings.values {
            XCTAssertNotNil(QualityModelAssetRegistry.baseline.asset(for: binding))
        }
    }
}
