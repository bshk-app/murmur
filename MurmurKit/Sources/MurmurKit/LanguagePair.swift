import Foundation

/// A translation direction, and the rules for reaching one with the models
/// Murmur actually ships.
public struct LanguagePair: Hashable, Sendable, CustomStringConvertible {
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

    /// How a direction is served.
    public enum Route: Equatable, Sendable {
        /// One model translates the pair outright.
        case direct(LanguagePair)
        /// Two models composed through English. The registry is English-centric,
        /// so this is the normal case for a non-English pair rather than a
        /// fallback: `fi-de` exists only as `fi-en` then `en-de`.
        case pivot(LanguagePair, LanguagePair)
    }

    /// Resolves `source -> target` into the models that serve it, or nil when
    /// either side is unsupported.
    ///
    /// Quality of a pivot is the composition of two models and is measurably
    /// worse than either leg; a caller that wants to say so to the user can
    /// match on `.pivot`.
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
