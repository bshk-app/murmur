import Foundation

/// Experimental Canary ASR/AST runtime. Weights load once; each bounded window
/// shares its encoder context between source transcription and direct translation.
public actor CanaryRuntime {
    public static let sampleRate = 16_000
    public static let maxSamples = 240_000
    // NVIDIA canary-1b-v2 model card, https://huggingface.co/nvidia/canary-1b-v2
    public static let supportedLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"
    ]
    public enum Failure: Error, Equatable, LocalizedError {
        case unsupportedLanguage(String), unsupportedTranslation(String, String), emptyAudio, exceedsShortWindow, invalidPCM, decoderLimit
        public var errorDescription: String? {
            switch self {
            case .unsupportedLanguage(let language): return "Canary does not support the language: \(language)."
            case .unsupportedTranslation(let source, let target): return "Direct Canary translation requires English on one side (\(source) → \(target))."
            case .emptyAudio: return "No audio samples were provided."
            case .exceedsShortWindow: return "Canary requires windows of at most 15 seconds."
            case .invalidPCM: return "Canary requires finite normalized mono 16 kHz PCM."
            case .decoderLimit: return "Canary reached the decoder limit before completing the text. Try a shorter audio window."
            }
        }
    }
    private let decoder: CanaryQualificationDecoder

    public init(modelsDirectory: URL) async throws {
        try Task.checkCancellation()
        let models = try await Task.detached(priority: .userInitiated) {
            try CanaryQualificationModels.load(directory: modelsDirectory)
        }.value
        try Task.checkCancellation()
        decoder = CanaryQualificationDecoder(models: models)
    }

    /// Samples must already be mono16kHz normalized Float PCM. No resampling,
    /// truncation or overlapping text merging is performed here.
    public func process(audio: [Float], sourceLanguage: String, targetLanguage: String? = nil) async throws -> CanaryResult {
        try Self.validateAudio(audio)
        try Self.validateLanguage(sourceLanguage)
        if let targetLanguage {
            try Self.validateLanguage(targetLanguage)
            guard Self.supportsTranslation(source: sourceLanguage, target: targetLanguage) else {
                throw Failure.unsupportedTranslation(sourceLanguage, targetLanguage)
            }
        }
        try Task.checkCancellation()
        return try await decoder.process(audio: audio, source: sourceLanguage, target: targetLanguage)
    }

    public nonisolated static func supportsTranslation(source: String, target: String) -> Bool {
        supportedLanguages.contains(source) && supportedLanguages.contains(target)
            && source != target && (source == "en" || target == "en")
    }

    public nonisolated static func validateLanguage(_ language: String) throws {
        guard supportedLanguages.contains(language) else { throw Failure.unsupportedLanguage(language) }
    }

    public nonisolated static func validateAudio(_ audio: [Float]) throws {
        guard !audio.isEmpty else { throw Failure.emptyAudio }
        guard audio.count <= maxSamples else { throw Failure.exceedsShortWindow }
        guard audio.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else { throw Failure.invalidPCM }
    }
}

public struct CanaryResult: Sendable, Equatable {
    public let sourceText: String
    public let translatedText: String?
    public init(sourceText: String, translatedText: String? = nil) {
        self.sourceText = sourceText; self.translatedText = translatedText
    }
}

/// Compatibility entry point for the existing short-clip qualification probes.
public actor CanaryQualificationRuntime {
    public static let sampleRate = CanaryRuntime.sampleRate
    public static let maxSamples = CanaryRuntime.maxSamples
    public static let supportedLanguages = CanaryRuntime.supportedLanguages
    public typealias Failure = CanaryRuntime.Failure
    private let runtime: CanaryRuntime
    private let source: String
    public init(modelsDirectory: URL, sourceLanguage: String) async throws {
        try CanaryRuntime.validateLanguage(sourceLanguage)
        source = sourceLanguage
        runtime = try await CanaryRuntime(modelsDirectory: modelsDirectory)
    }
    public func transcribe(audio: [Float]) async throws -> String {
        try await runtime.process(audio: audio, sourceLanguage: source).sourceText
    }
    public nonisolated static func validateLanguage(_ language: String) throws { try CanaryRuntime.validateLanguage(language) }
    public nonisolated static func validateAudio(_ audio: [Float]) throws { try CanaryRuntime.validateAudio(audio) }
}
