import Foundation
import MurmurCore

/// Uses the same installed quality models as voice translation, without a speech session.
public actor TextTranslationSession: TextTranslationEngine {
    private var quality = ProcessingQuality.quality
    public func setQuality(_ quality: ProcessingQuality) { self.quality = quality }
    public nonisolated func availableQualities(from: String, to: String) -> [ProcessingQuality] { ProcessingQuality.translationOptions(from: from, to: to) }
    private let service: TranslationService
    private let modelsRoot: URL
    public init(modelsRoot: URL, scenario: TranslationScenario = .text,
                profileCatalog: TranslationProfileCatalog = .current, device: TranslationDeviceClass = .current,
                assetRegistry: QualityModelAssetRegistry = .current) {
        self.modelsRoot = modelsRoot
        service = TranslationService(modelsRoot: modelsRoot, profileCatalog: profileCatalog, scenario: scenario, device: device, assetRegistry: assetRegistry)
    }
    public nonisolated static func availableTargets(from source: String, modelsRoot: URL,
        profileCatalog: TranslationProfileCatalog = .current, assetRegistry: QualityModelAssetRegistry = .current,
        device: TranslationDeviceClass = .current) -> [String] {
        let catalog = TranslationService(modelsRoot: modelsRoot, profileCatalog: profileCatalog, scenario: .text, device: device, assetRegistry: assetRegistry)
        return LanguagePair.qualityLanguages.sorted().filter { target in
            catalog.canPrepareQuality(from: source, to: target)
        }
    }
    private nonisolated static func legs(_ route: LanguagePair.Route) -> [LanguagePair] {
        switch route { case .direct(let pair): return [pair]; case .pivot(let first, let second): return [first, second] }
    }
    public func prepare(from: String, to: String, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        if from == to { return }
        if quality == .quality {
            try await service.prepareQuality(from: from, to: to) { onProgress($0.fraction) }
            return
        }
        guard let route = quality == .fast ? service.route(from: from, to: to) : service.qualityDownloadRoute(from: from, to: to) else { throw TranslationService.Unsupported(source: from, target: to) }
        let legs = Self.legs(route)
        if quality == .fast {
            for (index, leg) in legs.enumerated() {
                try Task.checkCancellation()
                try await TranslationDownloader.download(pair: leg, into: modelsRoot, kind: .fast) { progress in
                    onProgress((Double(index) + progress.fraction) / Double(legs.count))
                }
            }
            return
        }
    }
    public func translate(_ text: String, from: String, to: String) async throws -> String {
        try Task.checkCancellation()
        if quality == .fast { return try await service.translate(text, from: from, to: to) }
        let result = try await service.translateQuality(text, from: from, to: to)
        try Task.checkCancellation()
        return result.text
    }
    public var residentModelCount: Int { get async { await service.residentModelCount } }
    public func unload() async { await service.evictAll() }
}
