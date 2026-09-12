import Foundation
import MurmurCore

/// Keep downloaded packs protected between page chunks as well as during each native call.
public actor PageTranslationSession: TextTranslationEngine {
    private let root: URL
    private let inner: TextTranslationSession
    private var access: ModelFileAccess?
    public init(modelsRoot: URL, profileCatalog: TranslationProfileCatalog = .current,
                device: TranslationDeviceClass = .current, assetRegistry: QualityModelAssetRegistry = .current) {
        root = modelsRoot
        inner = TextTranslationSession(modelsRoot: modelsRoot, scenario: .page, profileCatalog: profileCatalog, device: device, assetRegistry: assetRegistry)
    }
    public func prepare(from: String, to: String, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        try await inner.prepare(from: from, to: to, onProgress: onProgress)
        try Task.checkCancellation()
        access = try ModelFileAccess.acquire(in: root, writing: false)
    }
    public func translate(_ text: String, from: String, to: String) async throws -> String { try await inner.translate(text, from: from, to: to) }
    public var residentModelCount: Int { get async { await inner.residentModelCount } }
    public func unload() async { await inner.unload(); access = nil }
}
