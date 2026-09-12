import Foundation
import CryptoKit
import MurmurCore

/// Transport and pinned bytes for a model identity. Directions/tags live in
/// TranslationModelBinding; one asset directory may serve multiple directions.
public struct QualityModelAsset: Sendable {
    public struct File: Sendable {
        public let name: String
        public let sha256: String
        public let bytes: Int
        public init(name: String, sha256: String, bytes: Int) {
            self.name = name; self.sha256 = sha256; self.bytes = bytes
        }
    }
    public enum Invalid: Error { case transport, files, identity, binding, duplicateDirectory }
    public let assetID: String
    public let directoryName: String
    public let baseURL: URL
    public let revision: String
    public let remoteDirectory: String
    public let files: [File]
    public var totalBytes: Int64 { files.reduce(0) { $0 + Int64($1.bytes) } }

    public init(assetID: String, directoryName: String, baseURL: URL, revision: String,
                remoteDirectory: String, files: [File]) throws {
        try self.init(assetID: assetID, directoryName: directoryName, baseURL: baseURL,
                      revision: revision, remoteDirectory: remoteDirectory, files: files, legacy: false)
    }
    fileprivate init(assetID: String, directoryName: String, baseURL: URL, revision: String,
                     remoteDirectory: String, files: [File], legacy: Bool) throws {
        func component(_ value: String) -> Bool {
            !value.isEmpty && value != "." && value != ".." &&
            value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }
        }
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil, component(directoryName), component(remoteDirectory),
              legacy || revision.range(of: #"^(?:[0-9a-f]{40}|[0-9a-f]{64})$"#, options: .regularExpression) != nil else { throw Invalid.transport }
        let names = Set(files.map(\.name))
        let required: Set<String> = ["model.bin", "config.json", "source.spm", "target.spm"]
        guard files.count <= 128, files.count == names.count, required.isSubset(of: names),
              names.contains("shared_vocabulary.json") || Set(["source_vocabulary.json", "target_vocabulary.json"]).isSubset(of: names),
              files.allSatisfy({ component($0.name) && $0.bytes > 0 && $0.bytes < 10_000_000_000 &&
                  $0.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil }) else { throw Invalid.files }
        let identityNames = required.union(["shared_vocabulary.json", "source_vocabulary.json", "target_vocabulary.json"])
        let rows = files.filter { identityNames.contains($0.name) }.sorted { $0.name < $1.name }.map { "\($0.name):\($0.sha256)" }
        let computed = "opus-" + SHA256.hash(data: Data(rows.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        guard computed == assetID else { throw Invalid.identity }
        self.assetID = assetID; self.directoryName = directoryName; self.baseURL = baseURL
        self.revision = revision; self.remoteDirectory = remoteDirectory; self.files = files
    }
    public func matches(_ binding: TranslationModelBinding) -> Bool {
        assetID == binding.modelID && directoryName == binding.directoryName
    }
    func isInstalled(in directory: URL) throws -> Bool {
        for file in files {
            guard try SharedQualityArtifacts.reusableFile(name: file.name, sha256: file.sha256,
                bytes: file.bytes, directories: [directory]) != nil || file.name == "target_tag.txt" &&
                (try? Data(contentsOf: directory.appendingPathComponent(file.name))).map({ data in
                    data.count == file.bytes && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == file.sha256
                }) == true else { return false }
        }
        do { return try TranslationModelIdentity.compute(directory: directory) == assetID }
        catch is CancellationError { throw CancellationError() }
        catch { return false }
    }
    var source: TranslationDownloader.Source {
        .init(baseURL: baseURL.appendingPathComponent(revision), directoryName: { _ in remoteDirectory }, compressionSuffix: "")
    }
}

public struct QualityModelAssetRegistry: Sendable {
    public static let baseline = try! QualityModelAssetRegistry()
    private let byDirectory: [String: QualityModelAsset]
    public init(additionalAssets: [QualityModelAsset] = []) throws {
        var assets: [String: QualityModelAsset] = [:]
        for binding in TranslationProfileCatalog.baseline.bindings.values {
            let key = binding.pair.source + binding.pair.target
            guard let pinned = TranslationQualityDigests.all[key] else { continue }
            let asset = try QualityModelAsset(assetID: binding.modelID, directoryName: binding.directoryName,
                baseURL: URL(string: "https://huggingface.co/beshkenadze/murmur-translation-ct2/resolve")!, revision: "main",
                remoteDirectory: binding.pair.source + "-" + binding.pair.target,
                files: pinned.files.map { .init(name: $0.name, sha256: $0.sha256, bytes: $0.bytes) }, legacy: true)
            assets[asset.directoryName] = asset
        }
        for asset in additionalAssets {
            guard asset.directoryName == asset.assetID, assets[asset.directoryName] == nil else { throw QualityModelAsset.Invalid.duplicateDirectory }
            assets[asset.directoryName] = asset
        }
        byDirectory = assets
    }
    public func asset(for binding: TranslationModelBinding) -> QualityModelAsset? {
        guard let asset = byDirectory[binding.directoryName], asset.matches(binding) else { return nil }
        return asset
    }
}
