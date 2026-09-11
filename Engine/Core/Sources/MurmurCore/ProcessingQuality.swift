import Foundation

public enum ProcessingQuality: String, CaseIterable, Sendable, Codable {
    case fast, quality
    public var title: String { self == .fast ? "Fast mode" : "Quality mode" }
    public static func translationOptions(from: String, to: String) -> [Self] {
        guard LanguagePair.qualityRoute(from: from, to: to) != nil else { return [] }
        return LanguagePair.route(from: from, to: to) == nil ? [.quality] : [.fast, .quality]
    }
}

public enum NoteContent: Sendable {
    case original, translation
    public func text(in note: VoiceNote) -> String {
        if self == .translation, let translation = note.translation, !translation.isEmpty { return translation }
        return note.text
    }
}

/// Selected languages get dictation plus both translation directions. English
/// connects the installed language packs, including a single selected language.
public struct OfflinePreloadPlan: Sendable {
    public let speech: [String]
    public let translationLanguages: [String]
    public let translations: [LanguagePair]
    public init(languages: Set<String>) {
        speech = languages.sorted()
        var linked = languages.intersection(LanguagePair.qualityLanguages)
        if !linked.isEmpty {
            linked.insert("en")
            if linked.count == 1 { linked.insert("ru") }
        }
        let ordered = linked.sorted()
        translationLanguages = ordered
        translations = ordered.flatMap { from in
            ordered.filter { $0 != from }.map { LanguagePair(source: from, target: $0) }
        }
    }
}
