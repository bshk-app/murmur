import Foundation
import Darwin

/// Opt-in coordination for a model store shared by an app and its extensions.
/// The lock file is permanent: unlinking it would create independent locks.
public final class ModelFileAccess: @unchecked Sendable {
    private let descriptor: Int32
    public struct Busy: LocalizedError {
        public var errorDescription: String? { "Language packs are being used by another Murmator window. Try again when it finishes." }
    }
    public static func enable(in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent(".model-access.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(fd)
    }
    public static func acquire(in root: URL, writing: Bool) throws -> ModelFileAccess? {
        let path = root.appendingPathComponent(".model-access.lock").path
        let fd = open(path, (writing ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil } // Private or bundled stores retain their existing behavior.
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(fd, (writing ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let failure = errno; close(fd)
            if failure == EWOULDBLOCK { throw Busy() }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        return ModelFileAccess(descriptor: fd)
    }
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
