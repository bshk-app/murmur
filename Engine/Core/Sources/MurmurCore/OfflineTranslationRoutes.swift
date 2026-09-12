import Foundation

public struct OfflineTranslationRoutes: Sendable {
    public let pairs: Set<LanguagePair>
    private let catalog: TranslationProfileCatalog
    private let scenario: TranslationScenario
    private let device: TranslationDeviceClass
    private struct Asset: Hashable { let id: String; let directory: String }
    private let installedAssets: Set<Asset>
    public init(pairs: Set<LanguagePair>, catalog: TranslationProfileCatalog = .current,
                scenario: TranslationScenario = .text, device: TranslationDeviceClass = .current) {
        self.pairs = pairs; self.catalog = catalog; self.scenario = scenario; self.device = device
        // The legacy pair-only API describes baseline installs, never a new
        // qualified model merely because it translates the same direction.
        self.installedAssets = Set(pairs.compactMap { TranslationProfileCatalog.baseline.bindings[$0] }
            .map { Asset(id: $0.modelID, directory: $0.directoryName) })
    }
    public init(installedModels: [TranslationModelBinding], catalog: TranslationProfileCatalog = .current,
                scenario: TranslationScenario = .text, device: TranslationDeviceClass = .current) {
        self.pairs = Set(installedModels.map(\.pair))
        self.catalog = catalog; self.scenario = scenario; self.device = device
        self.installedAssets = Set(installedModels.map { Asset(id: $0.modelID, directory: $0.directoryName) })
    }
    public var sources: [String] { Array(Set(pairs.map(\.source))).sorted() }
    public func targets(from source: String) -> [String] {
        LanguagePair.qualityLanguages.sorted().filter { target in
            guard target != source else { return false }
            guard let profile = catalog.resolve(.init(source: source, target: target, scenario: scenario, device: device)) else { return false }
            return profile.models.allSatisfy { installedAssets.contains(Asset(id: $0.modelID, directory: $0.directoryName)) }
        }
    }
}
