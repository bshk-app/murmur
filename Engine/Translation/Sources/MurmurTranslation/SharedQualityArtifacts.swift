import Foundation
import CryptoKit
import Darwin

/// Reuse immutable, hash-identical model files between direction directories.
/// Hard links keep the existing install/removal layout: removing one direction
/// cannot remove another direction's weights, and no orphan blob store is needed.
enum SharedQualityArtifacts {
    static func reusableFile(name: String, sha256: String, bytes: Int,
                             directories: [URL]) throws -> URL? {
        guard name != "target_tag.txt" else { return nil }
        for directory in directories {
            try Task.checkCancellation()
            let file = directory.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue == bytes else { continue }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            var digest = SHA256()
            // Avoid retaining autoreleased read buffers for an entire weight file.
            while try autoreleasepool(invoking: {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
                digest.update(data: data)
                return true
            }) {}
            if digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 { return file }
        }
        return nil
    }

    static func link(_ source: URL, into destination: URL) throws {
        try FileManager.default.linkItem(at: source, to: destination)
    }

    /// Caller holds the store writer lock. Only identical verified regular files
    /// are replaced; sibling hard links and open handles remain valid.
    static func consolidate(name: String, sha256: String, bytes: Int,
                            directories: [URL]) throws -> Int64 {
        guard name != "target_tag.txt" else { return 0 }
        let sorted = directories.sorted { $0.path < $1.path }
        // An already consolidated group needs no repeated multi-hundred-MB
        // digest scan. No bytes change when fewer than two distinct files exist.
        let identities = sorted.compactMap { directory -> String? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue == bytes,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
            return "\(device):\(inode)"
        }
        guard Set(identities).count > 1 else { return 0 }
        guard let canonical = try reusableFile(name: name, sha256: sha256, bytes: bytes, directories: sorted) else { return 0 }
        let identity = try FileManager.default.attributesOfItem(atPath: canonical.path)
        var consolidated: Int64 = 0
        for directory in sorted {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            if attributes[.systemNumber] as? NSNumber == identity[.systemNumber] as? NSNumber &&
               attributes[.systemFileNumber] as? NSNumber == identity[.systemFileNumber] as? NSNumber { continue }
            guard try reusableFile(name: name, sha256: sha256, bytes: bytes, directories: [directory]) != nil else { continue }
            let staged = directory.appendingPathComponent(".consolidating-" + UUID().uuidString)
            try link(canonical, into: staged)
            defer { try? FileManager.default.removeItem(at: staged) }
            try Task.checkCancellation()
            // rename replaces the directory entry atomically; old bytes remain
            // available until this succeeds, and through any other hard links.
            guard Darwin.rename(staged.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            consolidated += Int64(bytes)
        }
        return consolidated
    }

    static func publish(staging: URL, destination: URL) throws {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            try FileManager.default.moveItem(at: staging, to: destination)
            return
        }
        // Atomic directory exchange: a crash cannot leave destination absent.
        // On success the old directory is at staging and the caller removes it.
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
