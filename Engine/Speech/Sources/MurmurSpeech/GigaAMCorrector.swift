import MurmurCore
import Foundation
import CoreML
#if canImport(HuggingFace)
import HuggingFace
#endif

/// Synchronous inference is called only on PhoneCorrector's independent actor.
final class GigaAMCorrector {
    static let repo = "maxhlv/gigaam-v3-coreml"
    static let revision = "db44a79c2244cb9eb8178e383bd1ee92ec7fea25"
    private let encoder: MLModel
    private let predictor: MLModel
    private let joint: MLModel
    private let vocabulary: [Int: String]

    #if canImport(HuggingFace)
    static func load(ane: Bool, onProgress: @escaping @MainActor @Sendable (Progress) -> Void) async throws -> GigaAMCorrector {
        let repo = HuggingFace.Repo.ID(rawValue: repo)!
        let cache = HubCache.default
        let root = cache.snapshotsDirectory(repo: repo, kind: .model).appendingPathComponent(revision)
        let readiness = cache.cacheDirectory.appendingPathComponent("murmur-coreml-readiness")
        try FileManager.default.createDirectory(at: readiness, withIntermediateDirectories: true)
        let marker = readiness.appendingPathComponent("ready-gigaam-\(revision)")
        if !FileManager.default.fileExists(atPath: marker.path) {
            let client = HubClient(cache: cache)
            let entries = try await client.listFiles(in: repo, kind: .model, revision: revision, recursive: true)
            let roots = ["Encoder.mlmodelc/", "Predictor.mlmodelc/", "JointDecision.mlmodelc/"]
            let files = entries.filter { entry in
                entry.type == .file && (entry.path == "vocab.txt" || roots.contains { entry.path.hasPrefix($0) })
            }.map(\.path).sorted()
            guard !files.isEmpty else { throw CocoaError(.fileNoSuchFile) }
            _ = try await client.downloadSnapshot(of: repo, kind: .model, revision: revision,
                                                 matching: files, progressHandler: onProgress)
        }
        do {
            let model = try GigaAMCorrector(root: root, ane: ane)
            _ = try model.correct(Array(repeating: 0, count: 16000))
            try Data("validated".utf8).write(to: marker, options: .atomic)
            return model
        } catch {
            try? FileManager.default.removeItem(at: marker)
            throw error
        }
    }
    #endif

    init(root: URL, ane: Bool) throws {
        let enc = MLModelConfiguration(); enc.computeUnits = ane ? .cpuAndNeuralEngine : .cpuOnly
        let cpu = MLModelConfiguration(); cpu.computeUnits = .cpuOnly
        encoder = try MLModel(contentsOf: root.appendingPathComponent("Encoder.mlmodelc"), configuration: enc)
        predictor = try MLModel(contentsOf: root.appendingPathComponent("Predictor.mlmodelc"), configuration: cpu)
        joint = try MLModel(contentsOf: root.appendingPathComponent("JointDecision.mlmodelc"), configuration: cpu)
        let lines = try String(contentsOf: root.appendingPathComponent("vocab.txt"), encoding: .utf8).split(separator: "\n")
        vocabulary = Dictionary(uniqueKeysWithValues: lines.compactMap { line in
            guard let space = line.lastIndex(of: " "), let id = Int(line[line.index(after: space)...]) else { return nil }
            return (id, String(line[..<space]))
        })
        guard vocabulary[1024] == "<blk>" else { throw CocoaError(.fileReadCorruptFile) }
    }

    func correct(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        // Keep the fixed-shape export bounded; each phrase starts fresh RNNT state.
        var parts: [String] = []
        for start in stride(from: 0, to: samples.count, by: 480_000) {
            try Task.checkCancellation()
            parts.append(try decode(Array(samples[start..<min(start + 480_000, samples.count)])))
        }
        return parts.joined(separator: " ")
    }

    private func decode(_ samples: [Float]) throws -> String {
        let features = try GigaAMFrontend.features(samples)
        let mel = try Self.array([1, 64, 3000])
        for band in 0..<64 {
            for frame in 0..<min(features.frames, 3000) { mel[band * 3000 + frame] = NSNumber(value: features.values[band * features.frames + frame]) }
        }
        let encoded = try Self.output(encoder, ["audio_signal": mel], "encoded")
        let hidden = try Self.array([1, 1, 320]), cell = try Self.array([1, 1, 320])
        let token = try Self.array([1, 1], type: .int32)
        token[0] = 1024
        let encFrame = try Self.array([1, 768, 1]), decFrame = try Self.array([1, 320, 1])
        var tokens: [Int] = []
        // Two stride-2 padded convolutions: ceil(melFrames / 4).
        for frame in 0..<min(750, (features.frames + 3) / 4) {
            try Task.checkCancellation()
            for channel in 0..<768 { encFrame[channel] = encoded[[0, NSNumber(value: channel), NSNumber(value: frame)]] }
            for _ in 0..<10 {
                let prediction = try predictor.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x": token, "hi": hidden, "ci": cell]))
                guard let dec = prediction.featureValue(for: "dec")?.multiArrayValue,
                      let ho = prediction.featureValue(for: "ho")?.multiArrayValue,
                      let co = prediction.featureValue(for: "co")?.multiArrayValue else { throw CocoaError(.fileReadCorruptFile) }
                for i in 0..<320 { decFrame[i] = dec[i] }
                let id = try Self.output(joint, ["enc": encFrame, "dec": decFrame], "token_id")[0].intValue
                if id == 1024 { break }
                guard vocabulary[id] != nil else { throw CocoaError(.fileReadCorruptFile) }
                tokens.append(id); token[0] = NSNumber(value: id)
                // Commit recurrent state only when a nonblank symbol is emitted.
                for i in 0..<320 { hidden[i] = ho[i]; cell[i] = co[i] }
            }
        }
        return tokens.compactMap { vocabulary[$0] }.joined().replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func array(_ shape: [NSNumber], type: MLMultiArrayDataType = .float32) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: shape, dataType: type)
        for i in 0..<result.count { result[i] = 0 }
        return result
    }
    private static func output(_ model: MLModel, _ inputs: [String: MLMultiArray], _ name: String) throws -> MLMultiArray {
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        guard let array = result.featureValue(for: name)?.multiArrayValue else { throw CocoaError(.fileReadCorruptFile) }
        return array
    }
}
