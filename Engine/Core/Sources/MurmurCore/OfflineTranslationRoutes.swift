import Foundation

public struct OfflineTranslationRoutes: Sendable {
    public let pairs: Set<LanguagePair>
    public init(pairs: Set<LanguagePair>) { self.pairs = pairs }
    public var sources: [String] { Array(Set(pairs.map(\.source))).sorted() }
    public func targets(from source: String) -> [String] {
        LanguagePair.qualityLanguages.sorted().filter { target in
            guard target != source else { return false }
            return pairs.contains(.init(source: source, target: target)) ||
                (pairs.contains(.init(source: source, target: "en")) && pairs.contains(.init(source: "en", target: target)))
        }
    }
}
