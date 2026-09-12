@preconcurrency import CoreML

import Foundation

enum CanaryQualificationError: Error, LocalizedError {
    case processingFailed(String)
    var errorDescription: String? {
        if case .processingFailed(let message) = self { return message }
        return nil
    }
}


enum CanaryQualificationConfig {
    static let sampleRate = 16000
    static let maxSamples = 240000
    static let encoderHidden = 1024
    static let encoderFrames = 188
    static let maxDecoderSteps = 256
    static let eosId = 3
    static let promptEnTranscribePnc: [Int32] = [16053, 7, 4, 16, 64, 64, 5, 9, 11, 13]
}


/// Small detokenizer for the published vocabulary; no Python/MLX dependencies.
struct CanaryQualificationTokenizer: Sendable {
    let pieces: [Int: String]
    init(url: URL) throws {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        if let dictionary = value as? [String: String] {
            pieces = Dictionary(uniqueKeysWithValues: dictionary.compactMap { key, value in
                Int(key).map { ($0, value) }
            })
        } else if let array = value as? [String] {
            pieces = Dictionary(uniqueKeysWithValues: array.enumerated().map { ($0.offset, $0.element) })
        } else { throw CanaryQualificationError.processingFailed("Unsupported vocabulary format") }
        guard pieces.count == 16384 else { throw CanaryQualificationError.processingFailed("Incomplete vocabulary") }
    }
    func prompt(source: String, target: String) throws -> [Int32] {
        func id(_ language: String) throws -> Int32 {
            guard let value = pieces.first(where: { $0.value == "<|\(language)|>" })?.key else {
                throw CanaryQualificationError.processingFailed("Unsupported language: \(language)")
            }
            return Int32(value)
        }
        var prompt = CanaryQualificationConfig.promptEnTranscribePnc
        prompt[4] = try id(source)
        prompt[5] = try id(target)
        return prompt
    }
    func decode(ids: [Int]) -> String {
        var bytes = [UInt8]()
        for id in ids {
            guard let piece = pieces[id] else { continue }
            if piece.hasPrefix("<0x"), piece.hasSuffix(">"),
               let byte = UInt8(piece.dropFirst(3).dropLast(), radix: 16) {
                bytes.append(byte)
            } else {
                bytes.append(contentsOf: piece.replacingOccurrences(of: "▁", with: " ").utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct CanaryQualificationModels: Sendable {
    let preprocessor: MLModel
    let encoder: MLModel
    let decoder: MLModel
    let projection: MLModel
    let tokenizer: CanaryQualificationTokenizer

    static func load(directory: URL) throws -> CanaryQualificationModels {
        func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: directory.appendingPathComponent(name + ".mlmodelc"), configuration: configuration)
        }
        return try autoreleasepool {
            try CanaryQualificationModels(
                preprocessor: load("Preprocessor", .cpuOnly),
                encoder: load("EncoderInt4", .cpuAndGPU),
                decoder: load("DecoderInt4", .cpuAndGPU),
                projection: load("Projection", .cpuAndGPU),
                tokenizer: CanaryQualificationTokenizer(url: directory.appendingPathComponent("vocab.json")))
        }
    }
}
