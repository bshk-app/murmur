import CryptoKit
import Foundation

// Plain Foundation so Scripts/test-model-integrity.sh can compile it on its own.

/// One file of a model snapshot pinned to an exact revision. The size is the cheap
/// check made on every load; the SHA-256 proves the content after a download.
struct PinnedAsset: Sendable {
    let path: String
    let bytes: Int
    let sha256: String

    func hasExpectedSize(in directory: URL) -> Bool {
        (try? directory.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) == bytes
    }

    /// Throws `CocoaError(.fileReadCorruptFile)` when the size or hash differs from the pin.
    func verify(at url: URL) throws {
        try Task.checkCancellation()
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == bytes else { throw CocoaError(.fileReadCorruptFile) }
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
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else { throw CocoaError(.fileReadCorruptFile) }
    }

    /// Moves a download into `directory` only once it matches the pin; a bad download is deleted.
    func install(_ download: URL, in directory: URL) throws {
        do {
            try verify(at: download)
        } catch {
            try? FileManager.default.removeItem(at: download)
            throw error
        }
        let destination = directory.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: download)
        } else {
            try FileManager.default.moveItem(at: download, to: destination)
        }
    }
}

/// A model directory pinned to one revision. The marker records that every hash passed,
/// so later loads compare only sizes and a large model is hashed once per download.
struct PinnedSnapshot: Sendable {
    static let marker = ".murmur-verified"
    let revision: String
    let files: [PinnedAsset]

    func isVerified(in directory: URL) -> Bool {
        (try? String(contentsOf: directory.appendingPathComponent(Self.marker), encoding: .utf8)) == revision
            && files.allSatisfy { $0.hasExpectedSize(in: directory) }
    }

    /// Hashes every present file. A missing, truncated or altered one must be fetched again.
    func filesNeedingDownload(in directory: URL) throws -> [PinnedAsset] {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.marker))
        return try files.filter { file in
            do {
                try file.verify(at: directory.appendingPathComponent(file.path))
                return false
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return true
            }
        }
    }

    func markVerified(in directory: URL) throws {
        try Data(revision.utf8).write(to: directory.appendingPathComponent(Self.marker), options: .atomic)
    }
}
