import Foundation

/// A translation direction, and the rules for reaching one with the models
/// Murmur actually ships.
public struct LanguagePair: Hashable, Codable, Sendable, CustomStringConvertible {
    public let source: String
    public let target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }

    public var description: String { "\(source)-\(target)" }

    /// `models/moz-<source><target>`, the layout the downloader writes.
    public var modelDirectoryName: String { "moz-\(source)\(target)" }
}

extension LanguagePair {
    /// Directions with a stable, non-alpha Mozilla model in both senses,
    /// measured on FLORES+ devtest at chrF++ 46.6-71.1 depending on the pair.
    ///
    /// Alpha-model languages (da, el, hr, lt, lv, ro, sk, sv) are deliberately
    /// absent: shipping them would pin behaviour that upstream is about to
    /// replace. Maltese is absent because Mozilla publishes no `en-mt` at all.
    public static let supportedLanguages: Set<String> = [
        "bg", "cs", "de", "en", "es", "et", "fi", "fr",
        "hu", "it", "nl", "pl", "pt", "ru", "sl", "uk",
    ]

    /// All official EU languages, plus Russian and Ukrainian, plus languages the
    /// same OPUS checkpoints already carry (Catalan has its own en→ca model), plus Arabic.
    /// Independent of the smaller Mozilla preview-model catalog.
    public static let qualityLanguages: Set<String> = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "ga", "hr", "hu",
        "it", "lt", "lv", "mt", "nl", "pl", "pt", "ro", "sk", "sl", "sv", "ru", "uk",
        "be", "bs", "ca", "is", "mk", "nb", "sr", "ar",
    ]

    public static func qualityRoute(from source: String, to target: String) -> Route? {
        TranslationProfileCatalog.baseline.resolve(.init(source: source, target: target))?.route
    }

    /// How a direction is served.
    public enum Route: Equatable, Sendable {
        /// One model translates the pair outright.
        case direct(LanguagePair)
        /// Two models composed through English. The preview registry is
        /// English-centric. Quality profiles may also retain a pivot when a
        /// direct candidate has not demonstrated a quality improvement.
        case pivot(LanguagePair, LanguagePair)
    }

    /// Resolves `source -> target` into the models that serve it, or nil when
    /// either side is unsupported.
    ///
    /// This is the preview route. Quality selection belongs to the pinned
    /// profile catalog; direct versus pivot quality must be measured per pair.
    public static func route(from source: String, to target: String) -> Route? {
        guard source != target,
              supportedLanguages.contains(source),
              supportedLanguages.contains(target)
        else { return nil }
        if source == "en" || target == "en" {
            return .direct(LanguagePair(source: source, target: target))
        }
        return .pivot(
            LanguagePair(source: source, target: "en"),
            LanguagePair(source: "en", target: target)
        )
    }
}
