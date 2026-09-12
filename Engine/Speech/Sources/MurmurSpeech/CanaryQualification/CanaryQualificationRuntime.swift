import Foundation

/// Unqualified short-clip ASR candidate. This runtime is never selected by the
/// application speech-model menu or promoted to a production ASR profile.
public actor CanaryQualificationRuntime {
    public static let sampleRate = 16_000
    public static let maxSamples = 240_000
    // NVIDIA canary-1b-v2 model card, https://huggingface.co/nvidia/canary-1b-v2
    public static let supportedLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"
    ]
    public enum Failure: Error, Equatable {
        case unsupportedLanguage(String), emptyAudio, exceedsShortWindow, invalidPCM
    }
    private let decoder: CanaryQualificationDecoder

    public init(modelsDirectory: URL, sourceLanguage: String) async throws {
        try Self.validateLanguage(sourceLanguage)
        try Task.checkCancellation()
        let models = try await Task.detached(priority: .userInitiated) {
            try CanaryQualificationModels.load(directory: modelsDirectory)
        }.value
        try Task.checkCancellation()
        let prompt = try models.tokenizer.prompt(source: sourceLanguage, target: sourceLanguage)
        decoder = CanaryQualificationDecoder(models: models, prompt: prompt)
    }

    /// Samples must already be mono16kHz normalized Float PCM. No resampling,
    /// truncation or overlapping text merging is performed here.
    public func transcribe(audio: [Float]) async throws -> String {
        try Self.validateAudio(audio)
        try Task.checkCancellation()
        return try await decoder.transcribe(audio: audio)
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
