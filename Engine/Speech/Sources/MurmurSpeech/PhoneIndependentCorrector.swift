import MurmurCore
import Foundation
import CoreML
import WhisperKit

/// Independent Core ML lane: no MLX calls and GPU is excluded from compute units.
/// A task chain serializes whole utterances, including async Core ML predictions.
actor PhoneIndependentCorrector {
    private var whisper: WhisperKit?
    private var cohere: CoherePipeline?
    private var cohereModels: CoherePipeline.LoadedModels?
    private var previous: Task<String, Error>?
    private var serial: UInt64 = 0

    func load(choice: SpeechModelChoice, ane: Bool, modelsRoot: URL,
              onPreparation: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async throws {
        let root = modelsRoot.appendingPathComponent("CoreMLModels").appendingPathComponent(choice.rawValue)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("provenance.json").path) else {
            throw NSError(domain: "Murmur.Dual", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не установлены Core ML файлы для \(choice.title). Нужен отдельный набор для двойного режима."])
        }
        let units: MLComputeUnits = ane ? .cpuAndNeuralEngine : .cpuOnly
        if choice == .whisper {
            if whisper == nil {
                whisper = try await WhisperKit(WhisperKitConfig(modelFolder: root.path, tokenizerFolder: root,
                    computeOptions: ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: units, textDecoderCompute: units),
                    verbose: false, prewarm: false, load: true, download: false))
            }
        } else {
            if cohereModels == nil {
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent("encoder_manifest.json").path) else {
                    throw NSError(domain: "Murmur.Dual", code: 2, userInfo: [NSLocalizedDescriptionKey: "Нужен разбитый на модули Core ML энкодер. Монолитная версия превышает память iPhone."])
                }
                cohereModels = try await CoherePipeline.loadModels(encoderDir: root, decoderDir: root, vocabDir: root,
                                                                  decoderVariant: .v2, computeUnits: units, onPreparation: onPreparation)
                cohere = CoherePipeline()
            }
        }
    }

    func unload() async {
        if let whisper { await whisper.unloadModels() }
        whisper = nil; cohere = nil; cohereModels = nil; previous = nil
    }

    func correct(_ samples: [Float], language: String?, onExecutionStarted: @escaping @Sendable () async -> Void = {}) async throws -> String {
        let prior = previous
        let whisper = self.whisper, cohere = self.cohere, models = self.cohereModels
        serial &+= 1
        let id = serial
        let job = Task<String, Error> {
            _ = try? await prior?.value
            try Task.checkCancellation()
            await onExecutionStarted()
            if let whisper {
                let results = try await whisper.transcribe(audioArray: samples,
                    decodeOptions: DecodingOptions(verbose: false, task: .transcribe, language: language,
                                                   temperatureFallbackCount: 0, withoutTimestamps: true))
                return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let cohere, let models, let language = CohereAsrConfig.Language(rawValue: language ?? "en") else {
                throw CocoaError(.featureUnsupported)
            }
            return try await cohere.transcribe(audio: samples, models: models, language: language,
                                              maxNewTokens: 246, repetitionPenalty: 1.0, noRepeatNgram: 0).text
        }
        previous = job
        defer { if serial == id { previous = nil } }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
}
