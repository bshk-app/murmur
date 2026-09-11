import Foundation

/// Moves known packs into a shared store without replacing existing files.
/// Conflicting legacy copies remain available to the storage inventory.
public enum TranslationStoreMigration {
    public struct Result: Sendable {
        public let moved: [String]
        public let retained: [String]
    }
    public static func migrate(from legacy: URL, to destination: URL) throws -> Result {
        let fm = FileManager.default
        for root in [legacy, destination] where fm.fileExists(atPath: root.path) {
            guard try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
        try ModelFileAccess.enable(in: destination)
        guard legacy.standardizedFileURL != destination.standardizedFileURL,
              fm.fileExists(atPath: legacy.path) else { return Result(moved: [], retained: []) }
        let entries = try fm.contentsOfDirectory(atPath: legacy.path).filter { name in
            let allowed: Bool
            if name.hasPrefix(".staging-") {
                allowed = UUID(uuidString: String(name.dropFirst(9))) != nil
            } else {
                let code = String(name.dropFirst(4))
                allowed = (name.hasPrefix("ct2-") || name.hasPrefix("moz-")) && code.count == 4
                    && LanguagePair.qualityLanguages.contains(String(code.prefix(2)))
                    && LanguagePair.qualityLanguages.contains(String(code.suffix(2)))
                    && code.prefix(2) != code.suffix(2)
            }
            guard allowed else { return false }
            return try fm.attributesOfItem(atPath: legacy.appendingPathComponent(name).path)[.type] as? FileAttributeType == .typeDirectory
        }.sorted()
        let pending = entries.filter { !fm.fileExists(atPath: destination.appendingPathComponent($0).path) }
        guard !pending.isEmpty else { return Result(moved: [], retained: entries) }
        let access = try ModelFileAccess.acquire(in: destination, writing: true)
        defer { withExtendedLifetime(access) {} }
        var moved: [String] = [], retained: [String] = []
        for name in entries {
            let target = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { retained.append(name); continue }
            try fm.moveItem(at: legacy.appendingPathComponent(name), to: target)
            moved.append(name)
        }
        return Result(moved: moved, retained: retained)
    }
}
