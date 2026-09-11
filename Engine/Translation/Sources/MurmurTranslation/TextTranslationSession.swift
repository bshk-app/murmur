import Foundation
import MurmurCore

/// Uses the same installed quality models as voice translation, without a speech session.
public actor TextTranslationSession: TextTranslationEngine {
    private var quality = ProcessingQuality.quality
    public func setQuality(_ quality: ProcessingQuality) { self.quality = quality }
    public nonisolated func availableQualities(from: String, to: String) -> [ProcessingQuality] { ProcessingQuality.translationOptions(from: from, to: to) }
    private let service: TranslationService
    private let modelsRoot: URL
    public init(modelsRoot: URL) {
        self.modelsRoot = modelsRoot; service = TranslationService(modelsRoot: modelsRoot)
    }
    public nonisolated static func availableTargets(from source: String, modelsRoot: URL) -> [String] {
        let catalog = TranslationService(modelsRoot: modelsRoot)
        return LanguagePair.qualityLanguages.sorted().filter { target in
            guard let route = catalog.qualityDownloadRoute(from: source, to: target) else { return false }
            return legs(route).allSatisfy { catalog.hasQualityModel(for: $0) || TranslationDownloader.hasQualityDownload(for: $0) }
        }
    }
    private nonisolated static func legs(_ route: LanguagePair.Route) -> [LanguagePair] {
        switch route { case .direct(let pair): return [pair]; case .pivot(let first, let second): return [first, second] }
    }
    public func prepare(from: String, to: String, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
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
        for leg in legs where !service.hasQualityModel(for: leg) && !TranslationDownloader.hasQualityDownload(for: leg) {
            throw TranslationService.QualityUnavailable(pair: leg)
        }
        for (index, leg) in legs.enumerated() {
            try Task.checkCancellation()
            if !service.hasQualityModel(for: leg) {
                try await TranslationDownloader.download(pair: leg, into: modelsRoot, kind: .quality) { progress in
                    onProgress((Double(index) + progress.fraction) / Double(legs.count))
                }
            }
            await onProgress(Double(index + 1) / Double(legs.count))
        }
        try Task.checkCancellation()
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
