import Foundation
import CryptoKit
import Darwin
#if canImport(HuggingFace)
import HuggingFace
#endif

/// Immutable experimental model snapshot. Readiness checks only marker + file sizes;
/// all hashes are checked off the caller's actor before atomic publication.
public enum CanaryAssets {
    public static let repository = "FluidInference/canary-1b-v2-coreml"
    public static let revision = "75c1b536fe7ca6b589d2395ed9a43169d71f543b"
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MurMur/Canary/" + revision, isDirectory: true)
    }
    struct Asset: Sendable { let path: String; let bytes: Int; let sha256: String }
    static let files: [Asset] = [
        .init(path: "DecoderInt4.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "7891b0d2560a4dd42688707f4f19143d9ddc093e95ebfd057cac6d72004a6926"),
        .init(path: "DecoderInt4.mlmodelc/coremldata.bin", bytes: 535, sha256: "93bee0d2edd813e14e455c9f29985af3e0d14326e3dc0ea243614e12f6abeeee"),
        .init(path: "DecoderInt4.mlmodelc/model.mil", bytes: 619065, sha256: "273edfbfd33c00a83b92c7e30b4c13886a3bbb8e18d66dfe1c664c0f8d00d143"),
        .init(path: "DecoderInt4.mlmodelc/weights/weight.bin", bytes: 85404160, sha256: "33ea909de9c80ae8038c9f7a1ba3aa23436a2d5e6a114c372ad726ef466dcaaa"),
        .init(path: "EncoderInt4.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "c19ce81dc9c5e87c469f798c5bd8277504e16b1461a11c1f3022e63d1974b398"),
        .init(path: "EncoderInt4.mlmodelc/coremldata.bin", bytes: 496, sha256: "69133a332e90e81e6ded0ac3e3bca084725827f26e728eebba2d2bb3e40c38fc"),
        .init(path: "EncoderInt4.mlmodelc/model.mil", bytes: 1206065, sha256: "63305dba35b91876a84c9763f58d4ae7326bb2668d78c9dbc07339ab631a7a87"),
        .init(path: "EncoderInt4.mlmodelc/weights/weight.bin", bytes: 445374784, sha256: "c5fe0769def16fa51da5935b3388c637db51717443940313b011859a3daa409e"),
        .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "37ceefa42ac88362ef56185bdd8e7ad9e5be2017e45926d84389edac0f79ae2f"),
        .init(path: "Preprocessor.mlmodelc/coremldata.bin", bytes: 489, sha256: "154fb00859e58371e2ecb4e24e13973feabcf7cfdc2af9942cefa5ba96262bb5"),
        .init(path: "Preprocessor.mlmodelc/model.mil", bytes: 1837097, sha256: "65cef2bac598317009bca99d1a1deb4e2f25b0d63d077281b78dd4db1946529a"),
        .init(path: "Preprocessor.mlmodelc/weights/weight.bin", bytes: 976704, sha256: "f3c3d600f5fc6311ceff6406c10aeb4285a7f0fda4de6ac86b5bee3e76f80e32"),
        .init(path: "Projection.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "197d8355b690a758a57dc8d84fd24553963daf76d12b875adad8c6f0ae95b88c"),
        .init(path: "Projection.mlmodelc/coremldata.bin", bytes: 450, sha256: "8f4ece1f4baf433ded52a5615aa17b076bc4828b2970670f69c5c3d06b92a841"),
        .init(path: "Projection.mlmodelc/model.mil", bytes: 1668, sha256: "581c26de482180bfe649189f77abf3284e08c4c61e22553c15f22659fad27163"),
        .init(path: "Projection.mlmodelc/weights/weight.bin", bytes: 33587392, sha256: "de80cd5fff1851e391dd93706c2c05ac803189a8d951a370718c4595922db227"),
        .init(path: "README.md", bytes: 2697, sha256: "80b5a2d7b77896423ae0165c3f9170f918790a293090597201f9750679a64d43"),
        .init(path: "metadata.json", bytes: 512, sha256: "b590a78c4403a4664873c0f5098bf06ee5d00a70b5876db0aa237daf84860cae"),
        .init(path: "vocab.json", bytes: 306326, sha256: "a30b70ac13768821cda23590e40f80b2b7f24cd0c33edf3bcfabc9ad48dee72b"),
    ]
    public static var downloadBytes: Int64 { files.reduce(0) { $0 + Int64($1.bytes) } }
    public static func isReady(at directory: URL = defaultDirectory) -> Bool {
        guard (try? String(contentsOf: directory.appendingPathComponent(".ready"), encoding: .utf8)) == revision else { return false }
        return files.allSatisfy { (try? directory.appendingPathComponent($0.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) == $0.bytes }
    }
    /// Link the resolved regular Hub blob, never its snapshot symlink. The staged
    /// inode survives Hub-cache removal. Only filesystems that cannot link use a copy.
    static func stageFile(from source: URL, to destination: URL,
                          linkOperation: (URL, URL) -> Int32 = hardLink) throws {
        let resolved = source.resolvingSymlinksInPath()
        guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let result = linkOperation(resolved, destination)
        guard result != 0 else { return }
        if result == EXDEV || result == ENOTSUP || result == EOPNOTSUPP {
            try FileManager.default.copyItem(at: resolved, to: destination)
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
    }
    private static func hardLink(_ source: URL, _ destination: URL) -> Int32 {
        Darwin.link(source.path, destination.path) == 0 ? 0 : errno
    }

    static func verify(at directory: URL) throws {
        for file in files { try verify(file, at: directory.appendingPathComponent(file.path)) }
    }
    static func verify(_ file: Asset, at url: URL) throws {
        try Task.checkCancellation()
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == file.bytes else { throw CocoaError(.fileReadCorruptFile) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let count: Int = try autoreleasepool {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                hash.update(data: data)
                return data.count
            }
            if count == 0 { break }
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw CocoaError(.fileReadCorruptFile) }
    }

    /// A bad cached inode is never overwritten in place: existing publications may
    /// still link it. Fetch once without SDK/HTTP cache, verify, then replace only
    /// the private staging link. A bad fresh response fails the entire transaction.
    static func stageVerified(_ file: Asset, from cached: URL, to destination: URL,
                              fetchFresh: (Asset, URL) async throws -> Void) async throws {
        try stageFile(from: cached, to: destination)
        do { try verify(file, at: destination); return }
        catch let error as CocoaError where error.code == .fileReadCorruptFile { }
        let fresh = destination.deletingLastPathComponent().appendingPathComponent(".fresh-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fresh) }
        try Task.checkCancellation()
        try await fetchFresh(file, fresh)
        try verify(file, at: fresh)
        try Task.checkCancellation()
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: fresh, to: destination)
    }

    static func publish(_ staging: URL, at directory: URL) throws {
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: directory.path) {
            // Atomic exchange of complete directory entries. On success the old
            // tree moves to staging, where the installer's defer removes it.
            guard Darwin.renamex_np(staging.path, directory.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try FileManager.default.moveItem(at: staging, to: directory)
        }
    }
    #if canImport(HuggingFace)
    public static func prepare(at directory: URL = defaultDirectory,
        computeMode: CanaryRuntime.ComputeMode = .foreground,
        progress: @escaping @MainActor @Sendable (Progress) -> Void = { _ in }) async throws -> URL {
        try await CanaryAssetInstaller.shared.prepare(at: directory, computeMode: computeMode, progress: progress)
    }
    #endif
}

#if canImport(HuggingFace)
private actor CanaryAssetInstaller {
    static let shared = CanaryAssetInstaller()
    private var installing = Set<URL>()
    func prepare(at directory: URL, computeMode: CanaryRuntime.ComputeMode,
                 progress: @escaping @MainActor @Sendable (Progress) -> Void) async throws -> URL {
        if CanaryAssets.isReady(at: directory) {
            // A UI marker is only a hint. Verify content before loading even when size is unchanged.
            do { try CanaryAssets.verify(at: directory); return directory }
            catch is CancellationError { throw CancellationError() }
            catch {
                #if DEBUG
                NSLog("Canary installed asset verification failed: %@", String(describing: error as NSError))
                #endif
                /* Download and publish a fully verified replacement below. */
            }
        }
        // Concurrent installations to one destination are rejected; they cannot overwrite one another.
        guard installing.insert(directory.standardizedFileURL).inserted else { throw CocoaError(.fileWriteFileExists) }
        defer { installing.remove(directory.standardizedFileURL) }
        let manager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".canary-stage-" + UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let repo = Repo.ID(rawValue: CanaryAssets.repository)!
        let snapshot = try await HubClient(cache: .default).downloadSnapshot(of: repo, kind: .model,
            revision: CanaryAssets.revision, matching: CanaryAssets.files.map(\.path), progressHandler: progress)
        try Task.checkCancellation()
        for file in CanaryAssets.files {
            let destination = staging.appendingPathComponent(file.path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await CanaryAssets.stageVerified(file, from: snapshot.appendingPathComponent(file.path), to: destination) { asset, fresh in
                // cachePolicy alone does not bypass Hub's exact-revision cache fast path.
                // A cache-less client is required to fetch independently from the pin.
                _ = try await HubClient(cache: nil).downloadFile(at: asset.path, from: repo, to: fresh,
                    revision: CanaryAssets.revision, cachePolicy: .reloadIgnoringLocalCacheData, transport: .lfs)
            }
        }
        try CanaryAssets.verify(at: staging)
        // Confirm every compiled model and tokenizer can open before declaring the snapshot ready.
        try autoreleasepool {
            _ = try CanaryQualificationModels.load(directory: staging, computeMode: computeMode)
        }
        try Task.checkCancellation()
        try Data(CanaryAssets.revision.utf8).write(to: staging.appendingPathComponent(".ready"), options: .atomic)
        try CanaryAssets.publish(staging, at: directory)
        return directory
    }
}
#endif
