import XCTest
@testable import MurmurCore

final class ModelStorageTests: XCTestCase {
    private func fixture() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("murmator-storage-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private func write(_ root: URL, _ relative: String, bytes: Int) throws {
        let file=root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(repeating:7,count:bytes).write(to:file)
    }
    func testListsActualPackagesAndDeletesOnlySelectedDirection() async throws {
        let root=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        let models=root.appendingPathComponent("Models")
        try write(models,"TranslationModels/ct2-rufi/model.bin",bytes:1200)
        try write(models,"TranslationModels/ct2-firu/model.bin",bytes:900)
        try write(models,"TranslationModels/moz-ruen/model.bin",bytes:400)
        try write(root,"Notes/notes.json",bytes:50);try write(root,"AudioImports/source.m4a",bytes:70)
        let store=ModelStorage(modelsRoot:models)
        let before=try await store.inventory()
        XCTAssertEqual(before.items.count,3);XCTAssertEqual(before.totalBytes,2500)
        _ = try await store.remove(id:"translation/ct2-rufi")
        let after=try await store.inventory()
        XCTAssertEqual(after.totalBytes,1300)
        XCTAssertTrue(FileManager.default.fileExists(atPath:models.appendingPathComponent("TranslationModels/ct2-firu/model.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("Notes/notes.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("AudioImports/source.m4a").path))
        // Re-download/materialization is discovered without a stale cached inventory.
        try write(models,"TranslationModels/ct2-rufi/model.bin",bytes:1200)
        let restored=try await store.inventory();XCTAssertEqual(restored.items.count,3)
    }
    func testSharedSpeechRepositoryCountsBlobsOnceAndClearsReadiness() async throws {
        let root=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        try write(root,"cache/models--speech/blobs/one",bytes:1024)
        try write(root,"cache/readiness/ready",bytes:1)
        let snapshot=root.appendingPathComponent("cache/models--speech/snapshots/rev")
        try FileManager.default.createDirectory(at:snapshot,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(atPath:snapshot.appendingPathComponent("model.bin").path,withDestinationPath:"../../blobs/one")
        try FileManager.default.linkItem(at:root.appendingPathComponent("cache/models--speech/blobs/one"),to:snapshot.appendingPathComponent("hardlink.bin"))
        let marker=root.appendingPathComponent("cache/readiness/ready")
        let location=ModelStorageLocation(id:"speech/shared",root:root.appendingPathComponent("cache"),directory:root.appendingPathComponent("cache/models--speech"),title:"Shared",detail:"Shared by languages",markers:[marker])
        let store=ModelStorage(modelsRoot:root.appendingPathComponent("Models"),speech:[location])
        let inventory=try await store.inventory();XCTAssertEqual(inventory.totalBytes,1024)
        _ = try await store.remove(id:location.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:location.directory.path))
    }
    func testNeverFollowsSymlinksOrCallerSuppliedPaths() async throws {
        let root=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        let models=root.appendingPathComponent("Models"), outside=root.appendingPathComponent("Notes")
        try write(root,"Notes/notes.json",bytes:333)
        try FileManager.default.createDirectory(at:models.appendingPathComponent("TranslationModels"),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:models.appendingPathComponent("TranslationModels/ct2-rufi"),withDestinationURL:outside)
        let store=ModelStorage(modelsRoot:models)
        let inventory=try await store.inventory();XCTAssertTrue(inventory.items.isEmpty)
        let removed=try await store.remove(id:"translation/ct2-rufi");XCTAssertFalse(removed)
        let forged=try await store.remove(id:"../../Notes");XCTAssertFalse(forged)
        XCTAssertTrue(FileManager.default.fileExists(atPath:outside.appendingPathComponent("notes.json").path))
    }
    func testNestedSymlinkIsUnlinkedWithoutDeletingItsTarget() async throws {
        let root=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        let models=root.appendingPathComponent("Models")
        try write(models,"TranslationModels/ct2-rufi/model.bin",bytes:100)
        try write(root,"Notes/notes.json",bytes:300)
        try FileManager.default.createSymbolicLink(at:models.appendingPathComponent("TranslationModels/ct2-rufi/external"),withDestinationURL:root.appendingPathComponent("Notes"))
        let store=ModelStorage(modelsRoot:models)
        let inventory=try await store.inventory();XCTAssertEqual(inventory.totalBytes,100)
        _ = try await store.remove(id:"translation/ct2-rufi")
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("Notes/notes.json").path))
    }
    func testImportedAndInterruptedDownloadsRemainVisible() async throws {
        let root=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        try write(root,"CoreMLModels/custom/model.bin",bytes:100)
        try write(root,"TranslationModels/.staging-"+UUID().uuidString+"/partial",bytes:200)
        let store=ModelStorage(modelsRoot:root)
        let inventory=try await store.inventory()
        XCTAssertEqual(inventory.items.count,2)
        XCTAssertEqual(inventory.items.first(where:{$0.kind == .importedSpeech})?.downloadable,false)
        XCTAssertEqual(inventory.totalBytes,300)
    }
    func testGroupedCacheRemovalAndImportedReadinessAlias() async throws {
        let root=try fixture();defer { try? FileManager.default.removeItem(at:root) }
        try write(root,"cache/flat/model.bin",bytes:100)
        try write(root,"cache/repo/blobs/weights",bytes:200)
        try write(root,"cache/ready/revision",bytes:1)
        try write(root,"Models/ASRModels/custom/model.bin",bytes:300)
        let cache=root.appendingPathComponent("cache")
        let marker=cache.appendingPathComponent("ready/revision")
        let location=ModelStorageLocation(id:"speech/custom",root:cache,directory:cache.appendingPathComponent("flat"),title:"Shared",detail:"",markers:[marker],additionalDirectories:[cache.appendingPathComponent("repo")],invalidatedBy:["imported/ASRModels/custom"])
        let store=ModelStorage(modelsRoot:root.appendingPathComponent("Models"),speech:[location])
        let before=try await store.inventory();XCTAssertEqual(before.totalBytes,600)
        _ = try await store.remove(id:"imported/ASRModels/custom")
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:cache.appendingPathComponent("repo/blobs/weights").path))
        _ = try await store.remove(id:"speech/custom")
        XCTAssertFalse(FileManager.default.fileExists(atPath:cache.appendingPathComponent("repo").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:cache.appendingPathComponent("flat").path))
    }

}
