import Foundation
import CryptoKit

/// Content identity of the weights and tokenizer contract, independent of a
/// direction's target tag. Shared and split CTranslate2 vocabularies are supported.
public enum TranslationModelIdentity {
    private static let required = ["model.bin", "config.json", "source.spm", "target.spm"]
    private static let vocabularies = ["shared_vocabulary.json", "source_vocabulary.json", "target_vocabulary.json"]

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var identities: [String: String] = [:]
    }
    private static let cache = Cache()

    /// Cached content identity guarded by the store reader lock and all runtime
    /// files' inode/device/size/mtime signature. Atomic replacement invalidates it.
    /// Shared hard-linked directories reuse the same digest result.
    public static func cached(directory: URL) throws -> String {
        let access = try ModelFileAccess.acquire(in: directory.deletingLastPathComponent(), writing: false)
        defer { withExtendedLifetime(access) {} }
        try Task.checkCancellation()
        let signature = try fileSignature(directory: directory)
        cache.lock.lock()
        let existing = cache.identities[signature]
        cache.lock.unlock()
        if let existing { return existing }
        let identity = try compute(directory: directory)
        guard try fileSignature(directory: directory) == signature else { throw CocoaError(.fileReadCorruptFile) }
        cache.lock.lock()
        if cache.identities.count >= 128 { cache.identities.removeAll() }
        cache.identities[signature] = identity
        cache.lock.unlock()
        return identity
    }

    public static func compute(directory: URL) throws -> String {
        let names = try files(in: directory)
        let rows = try names.map { name in
            "\(name):\(try digest(file: directory.appendingPathComponent(name)))"
        }
        return "opus-" + hex(SHA256.hash(data: Data(rows.joined(separator: "\n").utf8)))
    }

    public static func fileSignature(directory: URL) throws -> String {
        try files(in: directory).map { name in
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadCorruptFile) }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(name):\(attributes[.size] ?? ""):\(modified):\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
        }.joined(separator: "\n")
    }

    private static func files(in directory: URL) throws -> [String] {
        let present = try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))
        guard Set(required).isSubset(of: present), present.contains("shared_vocabulary.json") ||
                Set(["source_vocabulary.json", "target_vocabulary.json"]).isSubset(of: present) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (required + vocabularies.filter(present.contains)).sorted()
    }

    private static func digest(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        // FileHandle's Foundation buffers may be autoreleased. Bound their
        // lifetime per chunk so hashing a model does not retain its full size.
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
            digest.update(data: data)
            return true
        }) {}
        return hex(digest.finalize())
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
