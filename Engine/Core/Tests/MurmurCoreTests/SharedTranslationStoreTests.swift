import XCTest
import Darwin
@testable import MurmurCore

final class SharedTranslationStoreTests: XCTestCase {
    private func fixture() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("murmator-shared-models-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private func write(_ root: URL, _ name: String, _ bytes: Int = 30) throws {
        let url=root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(repeating:7,count:bytes).write(to:url)
    }
    func testMigrationMovesPacksAndInterruptedDownloadsButPreservesOtherFiles() throws {
        let root=try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let legacy=root.appendingPathComponent("private/TranslationModels"), shared=root.appendingPathComponent("shared/TranslationModels")
        let staging=".staging-"+UUID().uuidString
        try write(legacy,"ct2-rufi/model.bin"); try write(legacy,"moz-ruen/model.bin")
        try write(legacy,staging+"/partial"); try write(legacy,"personal/file.txt")
        try write(root,"Notes/note.json")
        let result=try TranslationStoreMigration.migrate(from:legacy,to:shared)
        XCTAssertEqual(Set(result.moved),Set(["ct2-rufi","moz-ruen",staging]))
        XCTAssertTrue(FileManager.default.fileExists(atPath:shared.appendingPathComponent("ct2-rufi/model.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:legacy.appendingPathComponent("ct2-rufi").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:legacy.appendingPathComponent("personal/file.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("Notes/note.json").path))
        XCTAssertTrue(try TranslationStoreMigration.migrate(from:legacy,to:shared).moved.isEmpty)
    }
    func testConflictingCopiesStayVisibleAndDeletingLegacyDoesNotDeleteShared() async throws {
        let root=try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let models=root.appendingPathComponent("private/Models"), shared=root.appendingPathComponent("shared/TranslationModels")
        let legacy=models.appendingPathComponent("TranslationModels")
        try write(legacy,"ct2-rufi/model.bin",100); try write(shared,"ct2-rufi/model.bin",200)
        let migration=try TranslationStoreMigration.migrate(from:legacy,to:shared)
        XCTAssertEqual(migration.retained,["ct2-rufi"])
        let store=ModelStorage(modelsRoot:models,translationRoot:shared)
        let inventory=try await store.inventory()
        XCTAssertEqual(inventory.totalBytes,300)
        XCTAssertEqual(Set(inventory.items.map(\.id)),Set(["translation/ct2-rufi","legacy-translation/ct2-rufi"]))
        let removed=try await store.remove(id:"legacy-translation/ct2-rufi")
        XCTAssertTrue(removed)
        XCTAssertEqual(try Data(contentsOf:shared.appendingPathComponent("ct2-rufi/model.bin")).count,200)
    }
    func testSharedReaderPreventsDeletionAndMigrationUntilReleased() async throws {
        let root=try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let models=root.appendingPathComponent("private/Models"), shared=root.appendingPathComponent("shared/TranslationModels")
        let legacy=models.appendingPathComponent("TranslationModels")
        try write(shared,"ct2-rufi/model.bin"); try write(legacy,"ct2-firu/model.bin")
        try ModelFileAccess.enable(in:shared)
        let store=ModelStorage(modelsRoot:models,translationRoot:shared)
        do {
            let lease=try ModelFileAccess.acquire(in:shared,writing:false)
            defer { withExtendedLifetime(lease) {} }
            do { _ = try await store.remove(id:"translation/ct2-rufi"); XCTFail("Removed a pack while another reader was active") }
            catch is ModelFileAccess.Busy {}
            XCTAssertThrowsError(try TranslationStoreMigration.migrate(from:legacy,to:shared)) { XCTAssertTrue($0 is ModelFileAccess.Busy) }
            XCTAssertTrue(FileManager.default.fileExists(atPath:shared.appendingPathComponent("ct2-rufi/model.bin").path))
        }
        XCTAssertEqual(try TranslationStoreMigration.migrate(from:legacy,to:shared).moved,["ct2-firu"])
        let removed=try await store.remove(id:"translation/ct2-rufi"); XCTAssertTrue(removed)
    }
    func testMigrationRefusesSymbolicRootsAndDoesNotFollowPackageLinks() throws {
        let root=try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let legacy=root.appendingPathComponent("legacy"), shared=root.appendingPathComponent("shared")
        try write(root,"Notes/private.json")
        try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:legacy.appendingPathComponent("ct2-rufi"),withDestinationURL:root.appendingPathComponent("Notes"))
        XCTAssertTrue(try TranslationStoreMigration.migrate(from:legacy,to:shared).moved.isEmpty)
        let link=root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root.appendingPathComponent("Notes"))
        XCTAssertThrowsError(try TranslationStoreMigration.migrate(from:link,to:shared))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("Notes/private.json").path))
    }
    #if os(macOS)
    func testLockCoordinatesSeparateProcesses() throws {
        let root=try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        try ModelFileAccess.enable(in:root)
        let path=root.appendingPathComponent(".model-access.lock").path
        let helper = root.appendingPathComponent("lock-check")
        let source = root.appendingPathComponent("lock-check.c")
        try """
        #include <fcntl.h>
        #include <sys/file.h>
        #include <unistd.h>
        #include <errno.h>
        int main(int argc, char **argv) {
            if (argc != 2) return 4;
            int fd = open(argv[1], O_RDWR);
            if (fd < 0) return 2;
            int result = flock(fd, LOCK_EX | LOCK_NB);
            int status = result == 0 ? 0 : (errno == EWOULDBLOCK ? 1 : 3);
            close(fd);
            return status;
        }
        """.write(to:source,atomically:true,encoding:.utf8)
        let compiler=Process(); compiler.executableURL=URL(fileURLWithPath:"/usr/bin/xcrun")
        compiler.arguments=["clang",source.path,"-o",helper.path]
        try compiler.run(); compiler.waitUntilExit(); XCTAssertEqual(compiler.terminationStatus,0)
        func childCanWrite(_ expected: Bool) throws -> Bool {
            let child=Process(); child.executableURL=helper; child.arguments=[path]
            try child.run(); child.waitUntilExit()
            return child.terminationReason == .exit && child.terminationStatus == (expected ? 0 : 1)
        }
        do {
            let lease=try ModelFileAccess.acquire(in:root,writing:false)
            defer { withExtendedLifetime(lease) {} }
            XCTAssertTrue(try childCanWrite(false))
        }
        XCTAssertTrue(try childCanWrite(true))
    }
    #endif
}
