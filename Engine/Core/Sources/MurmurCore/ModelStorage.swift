import Foundation

public struct ModelStorageLocation: Sendable {
    public let id: String
    public let root: URL
    public let directory: URL
    public let title: String
    public let detail: String
    public let downloadable: Bool
    public let markers: [URL]
    public let additionalDirectories: [URL]
    public let invalidatedBy: [String]
    public init(id: String, root: URL, directory: URL, title: String, detail: String, downloadable: Bool = true, markers: [URL] = [], additionalDirectories: [URL] = [], invalidatedBy: [String] = []) {
        self.id=id; self.root=root; self.directory=directory; self.title=title; self.detail=detail; self.downloadable=downloadable; self.markers=markers; self.additionalDirectories=additionalDirectories; self.invalidatedBy=invalidatedBy
    }
}
public struct ModelStorageItem: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case translationQuality, translationPreview, speech, importedSpeech, incomplete }
    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    public let source: String?
    public let target: String?
    public let bytes: Int64
    public let fileCount: Int
    public let downloadable: Bool
    public init(id: String, kind: Kind, title: String, detail: String, source: String? = nil, target: String? = nil, bytes: Int64, fileCount: Int = 0, downloadable: Bool = true) {
        self.id=id; self.kind=kind; self.title=title; self.detail=detail; self.source=source; self.target=target; self.bytes=bytes; self.fileCount=fileCount; self.downloadable=downloadable
    }
}
public struct ModelStorageInventory: Sendable {
    public let items: [ModelStorageItem]
    public let totalBytes: Int64
    public let availableDiskBytes: Int64?
    public init(items: [ModelStorageItem] = [], totalBytes: Int64 = 0, availableDiskBytes: Int64? = nil) { self.items=items; self.totalBytes=totalBytes; self.availableDiskBytes=availableDiskBytes }
}

/// Enumerates and removes only known model packages. Notes, audio imports and
/// arbitrary Library/Caches entries are outside its catalog. Callers must hold
/// an application-wide model-work guard and close model owners before removal.
public actor ModelStorage {
    private let modelsRoot: URL
    private let translationRoot: URL
    private let speech: [ModelStorageLocation]
    private struct Candidate {
        let location: ModelStorageLocation
        let kind: ModelStorageItem.Kind
        var source: String? = nil
        var target: String? = nil
    }
    public init(modelsRoot: URL, speech: [ModelStorageLocation] = [], translationRoot: URL? = nil) {
        self.modelsRoot=modelsRoot; self.speech=speech
        self.translationRoot=translationRoot ?? modelsRoot.appendingPathComponent("TranslationModels")
    }
    public func inventory() throws -> ModelStorageInventory {
        var items: [ModelStorageItem] = [], counted: Set<String> = [], total: Int64 = 0
        for candidate in try candidates() {
            var files: [FileSize] = []
            for directory in [candidate.location.directory] + candidate.location.additionalDirectories {
                if let url = try safeURL(directory, within: candidate.location.root), FileManager.default.fileExists(atPath:url.path) { files += try regularFiles(in:url) }
            }
            var own: Set<String> = [], size: Int64 = 0
            for file in files {
                if own.insert(file.identity).inserted { size += file.size }
                if counted.insert(file.identity).inserted { total += file.size }
            }
            guard !files.isEmpty else { continue }
            items.append(.init(id:candidate.location.id,kind:candidate.kind,title:candidate.location.title,detail:candidate.location.detail,source:candidate.source,target:candidate.target,bytes:size,fileCount:own.count,downloadable:candidate.location.downloadable))
        }
        let capacity = try? modelsRoot.deletingLastPathComponent().resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        return .init(items:items.sorted { $0.id < $1.id },totalBytes:total,availableDiskBytes:capacity)
    }
    @discardableResult public func remove(id: String) throws -> Bool {
        guard let candidate = try candidates().first(where: { $0.location.id == id }) else { return false }
        let access = try [.translationQuality, .translationPreview, .incomplete].contains(candidate.kind)
            ? ModelFileAccess.acquire(in: candidate.location.root, writing: true) : nil
        defer { withExtendedLifetime(access) {} }
        // Clear readiness before deleting any weights. A partial deletion must
        // never leave a marker that causes the next preparation to skip download.
        let markerOwners = [candidate.location] + speech.filter { $0.invalidatedBy.contains(id) }
        for owner in markerOwners {
            for marker in owner.markers {
                if let checked = try safeURL(marker, within:owner.root), FileManager.default.fileExists(atPath:checked.path) { try FileManager.default.removeItem(at:checked) }
            }
        }
        for directory in [candidate.location.directory] + candidate.location.additionalDirectories {
            if let url = try safeURL(directory, within:candidate.location.root), FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
        }
        return true
    }
    private func candidates() throws -> [Candidate] {
        var result = speech.map { Candidate(location:$0,kind:.speech) }
        let legacyRoot = modelsRoot.appendingPathComponent("TranslationModels")
        let roots = [translationRoot] + (legacyRoot.standardizedFileURL == translationRoot.standardizedFileURL ? [] : [legacyRoot])
        for (index, translations) in roots.enumerated() {
            let legacy = index > 0
            for child in try children(translations, within: translations.deletingLastPathComponent()) {
                let name = child.lastPathComponent
                let prefix = name.hasPrefix("ct2-") ? "ct2-" : name.hasPrefix("moz-") ? "moz-" : ""
                let detail = legacy ? "Extra copy of a language pack from an earlier app version." : "A direction may also be used by translations through an intermediate language."
                if !prefix.isEmpty {
                    let code = String(name.dropFirst(prefix.count))
                    guard code.count == 4 else { continue }
                    let from = String(code.prefix(2)), to = String(code.suffix(2))
                    guard from != to, LanguagePair.qualityLanguages.contains(from), LanguagePair.qualityLanguages.contains(to) else { continue }
                    result.append(.init(location: .init(id: (legacy ? "legacy-translation/" : "translation/") + name, root: translations, directory: child, title: prefix == "ct2-" ? "Translation" : "Live translation preview", detail: detail), kind: prefix == "ct2-" ? .translationQuality : .translationPreview, source: from, target: to))
                } else if name.hasPrefix(".staging-"), UUID(uuidString: String(name.dropFirst(9))) != nil {
                    result.append(.init(location: .init(id: (legacy ? "legacy-incomplete/" : "incomplete/") + name, root: translations, directory: child, title: "Unfinished model download", detail: "Temporary files from a model download."), kind: .incomplete))
                }
            }
        }
        for folder in ["ASRModels","CoreMLModels"] {
            for child in try children(modelsRoot.appendingPathComponent(folder),within:modelsRoot) {
                result.append(.init(location:.init(id:"imported/"+folder+"/"+child.lastPathComponent,root:modelsRoot,directory:child,title:"Imported speech pack",detail:child.lastPathComponent,downloadable:false),kind:.importedSpeech))
            }
        }
        return result
    }
    private func children(_ directory: URL, within root: URL) throws -> [URL] {
        guard let checked=try safeURL(directory,within:root),FileManager.default.fileExists(atPath:checked.path) else { return [] }
        // Preserve the original root spelling, so canonical /var aliases don't
        // change the relative-path fence used by safeURL on the next call.
        return try FileManager.default.contentsOfDirectory(atPath:checked.path).map { directory.appendingPathComponent($0) }.filter {
            guard let url=try safeURL($0,within:root) else { return false }
            return (try FileManager.default.attributesOfItem(atPath:url.path)[.type] as? FileAttributeType) == .typeDirectory
        }
    }
    private func safeURL(_ url: URL, within root: URL) throws -> URL? {
        let base=root.standardizedFileURL, candidate=url.standardizedFileURL
        guard candidate.path.hasPrefix(base.path + "/") else { return nil }
        let relative=String(candidate.path.dropFirst(base.path.count + 1))
        var current=base.resolvingSymlinksInPath()
        for component in relative.split(separator:"/") {
            current.appendPathComponent(String(component))
            do {
                if try FileManager.default.attributesOfItem(atPath:current.path)[.type] as? FileAttributeType == .typeSymbolicLink { return nil }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { continue }
        }
        return current
    }
    private struct FileSize { let identity: String; let size: Int64 }
    private func regularFiles(in directory: URL) throws -> [FileSize] {
        var enumerationError: Error?
        guard let enumerator=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:nil,errorHandler:{ _,error in enumerationError=error; return false }) else { return [] }
        var result: [FileSize] = []
        for case let file as URL in enumerator {
            let attributes=try FileManager.default.attributesOfItem(atPath:file.path)
            let type=attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink { enumerator.skipDescendants(); continue }
            guard type == .typeRegular else { continue }
            let identity: String
            if let device=attributes[.systemNumber],let inode=attributes[.systemFileNumber] { identity="\(device):\(inode)" } else { identity=file.path }
            result.append(.init(identity:identity,size:(attributes[.size] as? NSNumber)?.int64Value ?? 0))
        }
        if let enumerationError { throw enumerationError }
        return result
    }
}
