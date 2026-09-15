import MurmurCore
import Foundation
import HuggingFace
import MLX
import MLXAudioSTT

/// Owned by PhoneStreamingEngine: VAD and batch inference share one actor.
/// No second MLX executor or unsupported MLX CPU fallback is introduced.
final class PhoneMLXCorrector {
    private let model: any STTGenerationModel
    private init(model: any STTGenerationModel) { self.model = model }

    static func modelSource(for choice: SpeechModelChoice) throws -> (name: String, revision: String) {
        let name: String, revision: String
        switch choice {
        case .cohere:
            name = "beshkenadze/cohere-transcribe-03-2026-mlx-4bit"
            revision = "104bc4391b5b1a12b040859793d7148525e1a08c"
        case .cohereArabic:
            name = "majentik/cohere-transcribe-arabic-07-2026-MLX-4bit"
            revision = "df607f21f9f340e09a1825f851c727295b1cb0ec"
        case .whisper:
            name = "mlx-community/whisper-large-v3-turbo-asr-4bit"
            revision = "321a6ead9f6e0646bc8188a54d2a470e275c6b76"
        default: throw CocoaError(.featureUnsupported)
        }
        return (name, revision)
    }

    static func load(_ choice: SpeechModelChoice, modelsRoot: URL,
                     onProgress: @escaping @MainActor @Sendable (Progress) -> Void) async throws -> PhoneMLXCorrector {
        let (name, revision) = try modelSource(for: choice)
        let cache = HubCache.default
        let repo = Repo.ID(rawValue: name)!
        var root = cache.snapshotsDirectory(repo: repo, kind: .model).appendingPathComponent(revision)
        let staged = modelsRoot.appendingPathComponent("ASRModels").appendingPathComponent(choice.rawValue)
        let stagedRevision = try? String(contentsOf: staged.appendingPathComponent("revision.txt"), encoding: .utf8)
        let hasStagedModel = stagedRevision?.trimmingCharacters(in: .whitespacesAndNewlines) == revision
        if hasStagedModel { root = staged }
        let markers = cache.cacheDirectory.appendingPathComponent("murmur-mlx-readiness")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let marker = markers.appendingPathComponent(revision)
        if !hasStagedModel && !FileManager.default.fileExists(atPath: marker.path) {
            let client = HubClient(cache: cache)
            let files = try await client.listFiles(in: repo, kind: .model, revision: revision, recursive: true)
            let paths = files.filter { entry in
                entry.type == .file && ["json", "safetensors", "model", "txt"].contains(URL(fileURLWithPath: entry.path).pathExtension)
            }.map(\.path).sorted()
            _ = try await client.downloadSnapshot(of: repo, kind: .model, revision: revision,
                                                  matching: paths, progressHandler: onProgress)
        }
        do {
            let model: any STTGenerationModel
            if choice == .whisper {
                model = try await Device.withDefaultDevice(.gpu) { try await WhisperModel.fromDirectory(root) }
            } else {
                model = try Device.withDefaultDevice(.gpu) { try CohereTranscribeModel.fromDirectory(root) }
            }
            try Data("loaded".utf8).write(to: marker, options: .atomic)
            return PhoneMLXCorrector(model: model)
        } catch {
            try? FileManager.default.removeItem(at: marker)
            throw error
        }
    }

    func correct(_ samples: [Float], language: String?) throws -> String {
        try Task.checkCancellation()
        return Device.withDefaultDevice(.gpu) {
            let parameters = STTGenerateParameters(maxTokens: 448, temperature: 0,
                topP: 1, topK: 0, verbose: false, language: SpeechModelChoice.whisperLanguageCode(language), chunkDuration: 30, minChunkDuration: 0.1)
            let result = model.generate(audio: MLXArray(samples), generationParameters: parameters)
            return result.text
        }
    }
}
