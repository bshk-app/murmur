import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum TranslationScenario: String, Codable, Hashable, Sendable {
    case dictation, text, page
}

public enum TranslationDeviceClass: String, Codable, Hashable, Sendable {
    case iPhone15Pro, other

    public static var current: Self {
        #if os(iOS) && !targetEnvironment(simulator)
        var system = utsname()
        guard uname(&system) == 0 else { return .other }
        let capacity = MemoryLayout.size(ofValue: system.machine)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        return machine == "iPhone16,1" ? .iPhone15Pro : .other
        #else
        return .other
        #endif
    }
}

public struct TranslationProfileRequest: Codable, Hashable, Sendable {
    public let pair: LanguagePair
    public let scenario: TranslationScenario
    public let device: TranslationDeviceClass

    public init(source: String, target: String, scenario: TranslationScenario = .dictation,
                device: TranslationDeviceClass = .other) {
        pair = .init(source: source, target: target)
        self.scenario = scenario
        self.device = device
    }
}

/// A language direction is a binding to weights, not the identity of those weights.
/// Several bindings may share modelID while keeping distinct target tags.
public struct TranslationModelBinding: Codable, Hashable, Sendable {
    public let pair: LanguagePair
    public let modelID: String
    public let directoryName: String
    public let targetTag: String
    public let decoding: TranslationDecodingProfile

    public init(pair: LanguagePair, modelID: String, directoryName: String,
                targetTag: String = "", decoding: TranslationDecodingProfile = .baseline) {
        self.pair = pair
        self.modelID = modelID
        self.directoryName = directoryName
        self.targetTag = targetTag
        self.decoding = decoding
    }
}

public struct TranslationProfile: Codable, Hashable, Sendable {
    public enum Qualification: String, Codable, Sendable { case baseline, qualified }
    public let catalogVersion: String
    public let request: TranslationProfileRequest
    public let models: [TranslationModelBinding]
    public let qualification: Qualification
    public let evidenceID: String?

    public init(catalogVersion: String, request: TranslationProfileRequest,
                models: [TranslationModelBinding], qualification: Qualification = .baseline,
                evidenceID: String? = nil) {
        self.catalogVersion = catalogVersion
        self.request = request
        self.models = models
        self.qualification = qualification
        self.evidenceID = evidenceID
    }

    public var route: LanguagePair.Route? {
        if models.count == 1 { return .direct(models[0].pair) }
        if models.count == 2 { return .pivot(models[0].pair, models[1].pair) }
        return nil
    }

    public var diagnosticID: String {
        "\(catalogVersion):\(request.pair):\(request.scenario.rawValue):\(request.device.rawValue)"
    }
}

/// Deterministic selection, independent of which files happen to be installed.
/// Qualified replacements are generated after the external evidence gate, then
/// explicitly enabled for internal rollout. An absent match retains baseline.
public struct TranslationProfileCatalog: Sendable {
    public enum Invalid: Error { case duplicate, invalidModel, invalidRoute, missingEvidence }
    public let version: String
    public let bindings: [LanguagePair: TranslationModelBinding]
    public let registeredModels: [TranslationModelBinding]
    private let replacements: [TranslationProfileRequest: TranslationProfile]
    private let enableQualifiedProfiles: Bool

    public init(version: String, bindings: [TranslationModelBinding], additionalModels: [TranslationModelBinding] = [],
                qualifiedProfiles: [TranslationProfile] = [], enableQualifiedProfiles: Bool = false) throws {
        guard Set(bindings.map(\.pair)).count == bindings.count else { throw Invalid.duplicate }
        let registered = bindings + additionalModels
        for binding in registered { try Self.validate(binding) }
        guard Set(qualifiedProfiles.map(\.request)).count == qualifiedProfiles.count else { throw Invalid.duplicate }
        for profile in qualifiedProfiles {
            guard profile.qualification == .qualified,
                  let evidence = profile.evidenceID, !evidence.isEmpty else { throw Invalid.missingEvidence }
            guard profile.catalogVersion == version,
                  Self.validRoute(profile.models, pair: profile.request.pair) else { throw Invalid.invalidRoute }
            for model in profile.models {
                try Self.validate(model)
                // Replacement weights must be part of the same pinned catalog.
                guard registered.contains(where: { $0 == model }) else { throw Invalid.invalidModel }
            }
        }
        self.version = version
        self.bindings = Dictionary(uniqueKeysWithValues: bindings.map { ($0.pair, $0) })
        self.registeredModels = registered
        self.replacements = Dictionary(uniqueKeysWithValues: qualifiedProfiles.map { ($0.request, $0) })
        self.enableQualifiedProfiles = enableQualifiedProfiles
    }

    public func resolve(_ request: TranslationProfileRequest) -> TranslationProfile? {
        let pair = request.pair
        guard pair.source != pair.target,
              LanguagePair.qualityLanguages.contains(pair.source),
              LanguagePair.qualityLanguages.contains(pair.target) else { return nil }
        if enableQualifiedProfiles, let selected = replacements[request] { return selected }
        let models: [TranslationModelBinding]
        if let direct = bindings[pair] {
            models = [direct]
        } else if let first = bindings[.init(source: pair.source, target: "en")],
                  let second = bindings[.init(source: "en", target: pair.target)] {
            models = [first, second]
        } else { return nil }
        return .init(catalogVersion: version, request: request, models: models)
    }

    private static func validate(_ model: TranslationModelBinding) throws {
        guard model.pair.source != model.pair.target,
              LanguagePair.qualityLanguages.contains(model.pair.source),
              LanguagePair.qualityLanguages.contains(model.pair.target),
              !model.modelID.isEmpty, !model.directoryName.isEmpty,
              model.directoryName != ".", model.directoryName != "..",
              !model.directoryName.contains("/"), !model.directoryName.contains("\\") else { throw Invalid.invalidModel }
        let tag = model.targetTag
        guard tag.isEmpty || ((5...64).contains(tag.utf8.count) && tag.hasPrefix(">>") && tag.hasSuffix("<<") &&
                              tag.utf8.allSatisfy { $0 > 0x20 }) else { throw Invalid.invalidModel }
        try model.decoding.validate()
    }

    private static func validRoute(_ models: [TranslationModelBinding], pair: LanguagePair) -> Bool {
        guard (1...2).contains(models.count), models.first?.pair.source == pair.source,
              models.last?.pair.target == pair.target else { return false }
        return models.count == 1 || (models[0].pair.target == "en" && models[1].pair.source == "en")
    }
}

extension TranslationProfileCatalog {
    /// The application and its extensions share this internal rollout decision.
    /// Populate these tables only from a reviewed, passing qualification bundle.
    public static let current: TranslationProfileCatalog = {
        let enableQualifiedProfiles = false
        let additionalModels: [TranslationModelBinding] = []
        let approvedProfiles: [TranslationProfile] = []
        guard enableQualifiedProfiles else { return .baseline }
        return try! TranslationProfileCatalog(version: baseline.version,
            bindings: Array(baseline.bindings.values), additionalModels: additionalModels,
            qualifiedProfiles: approvedProfiles, enableQualifiedProfiles: true)
    }()
}
