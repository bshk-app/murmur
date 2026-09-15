import Foundation

public enum SpeechModelChoice: String, CaseIterable {
    case gigaam, parakeet, cohere, cohereArabic, whisper
    public var usesGPU: Bool { self == .cohere || self == .cohereArabic || self == .whisper }
    public var title: String {
        switch self {
        case .gigaam: return "GigaAM v3 · русский"
        case .parakeet: return "Parakeet v3"
        case .cohere: return "Cohere Transcribe"
        case .cohereArabic: return "Cohere Arabic"
        case .whisper: return "Whisper large-v3 turbo"
        }
    }
    /// Translation languages Parakeet does not recognize; Whisper transcribes them.
    public static let whisperLanguages: Set<String> = ["be", "bs", "ca", "is", "mk", "nb", "sr"]
    public static let parakeetLanguages = LanguagePair.qualityLanguages.subtracting(whisperLanguages.union(["ga", "ar"]))
    /// Whisper names Norwegian `no`; iOS names written Norwegian Bokmål `nb`.
    public static func whisperLanguageCode(_ language: String?) -> String? {
        language == "nb" ? "no" : language
    }
    public static func languages(forStorageID id: String, selected: [String]) -> [String] {
        selected.filter { code in
            switch id {
            case "speech/detection-live", "speech/detection-files": return true
            case "speech/russian-accurate": return Self.gigaam.supports(code)
            case "speech/multilingual-accurate": return Self.parakeet.supports(code)
            case "speech/live": return DictationMode.allowsLiveDraft(language: code)
            case "speech/additional-whisper": return Self.whisper.supports(code)
            case "speech/additional-cohere": return Self.cohere.supports(code)
            case "speech/additional-cohereArabic": return Self.cohereArabic.supports(code)
            default: return false
            }
        }
    }
    public func supports(_ language: String) -> Bool {
        switch self {
        case .gigaam: return language == "ru"
        case .cohereArabic: return language == "ar" || language == "en"
        case .cohere: return ["en", "de", "es", "fr", "it", "pt", "el", "pl", "nl", "ja", "zh", "ko", "vi", "ar"].contains(language)
        case .parakeet: return Self.parakeetLanguages.contains(language)
        case .whisper: return true
        }
    }
}
