import Foundation

/// Detects a safetensors file cut short, e.g. by an interrupted download. MLX loads such
/// a file without an error and fills the missing tensors with whatever it reads, so the
/// model runs but produces nothing useful.
public enum SafetensorsIntegrity {
    /// True when the file is long enough to hold every tensor its header lists:
    /// 8-byte little-endian header length + JSON header + the furthest `data_offsets` end.
    /// Reads only the header; trailing bytes are tolerated so they never force a re-download.
    public static func isComplete(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 8, (try? handle.seek(toOffset: 0)) != nil,
              let prefix = try? handle.read(upToCount: 8), prefix.count == 8 else { return false }
        let headerLength = prefix.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        // The format caps the header at 100 MB; anything larger is not a safetensors header.
        guard headerLength <= 100_000_000, 8 + headerLength <= size,
              let header = try? handle.read(upToCount: Int(headerLength)), header.count == Int(headerLength),
              let tensors = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any] else { return false }
        var dataEnd: UInt64 = 0
        for (name, entry) in tensors where name != "__metadata__" {
            guard let offsets = (entry as? [String: Any])?["data_offsets"] as? [NSNumber], offsets.count == 2 else { return false }
            dataEnd = max(dataEnd, offsets[1].uint64Value)
        }
        return dataEnd <= size - 8 - headerLength // Subtraction: a forged offset must not overflow.
    }

    /// A non-empty file of the required extension exists and no safetensors file in
    /// `directory` is cut short. Murmur patch: upstream accepted any non-empty file.
    public static func hasCompleteWeights(in directory: URL, requiredExtension: String) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let hasRequiredFile = files.contains { file in
            file.pathExtension == requiredExtension
                && ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
        }
        return hasRequiredFile && files.filter { $0.pathExtension == "safetensors" }.allSatisfy(isComplete(at:))
    }
}
