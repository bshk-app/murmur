import XCTest
import MLX
import MLXAudioSTT
import AVFoundation

/// Opt-in strict checkpoint/schema validation on Mac. This does not measure
/// inference quality, GPU behavior or iPhone memory/performance.
final class MobileCheckpointLoadTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        guard let root = ProcessInfo.processInfo.environment["MURMUR_MOBILE_MODEL_ROOT"] else {
            throw XCTSkip("Set MURMUR_MOBILE_MODEL_ROOT to staged mobile test weights")
        }
        return URL(fileURLWithPath: root).appendingPathComponent(name)
    }

    func test_cohere_checkpoint_loads() throws {
        let root = try directory("cohere")
        try Device.withDefaultDevice(.cpu) {
            let model = try CohereTranscribeModel.fromDirectory(root)
            XCTAssertGreaterThan(model.config.vocabSize, 0)
        }
    }

    func test_arabic_checkpoint_and_prompt_load() throws {
        let root = try directory("cohereArabic")
        try Device.withDefaultDevice(.cpu) {
            let model = try CohereTranscribeModel.fromDirectory(root)
            let tokenizer = try CohereTranscribeTokenizer(modelDir: root, config: model.config)
            let prompt = tokenizer.buildPromptTokens(language: "ar")
            XCTAssertEqual(prompt.count, 9)
            XCTAssertNotEqual(prompt, tokenizer.buildPromptTokens(language: "en"))
        }
    }

    func test_whisper_checkpoint_loads() async throws {
        let root = try directory("whisper")
        try await Device.withDefaultDevice(.cpu) {
            _ = try await WhisperModel.fromDirectory(root)
        }
    }

    func test_whisper_quantized_embedding_generates_on_gpu() async throws {
        let root = try directory("whisper")
        let corpus = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ASRCorpus")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("manifest.json"))) as! [String: Any]
        let clip = (manifest["clips"] as! [[String: Any]]).first { $0["language"] as? String == "fi" }!
        let file = try AVAudioFile(forReading: corpus.appendingPathComponent(clip["filename"] as! String))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        try await Device.withDefaultDevice(.gpu) {
            let model = try await WhisperModel.fromDirectory(root)
            let result = model.generate(audio: MLXArray(samples), generationParameters: STTGenerateParameters(maxTokens: 128, language: "fi"))
            XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            print("WHISPER_MAC_CHECK:", result.text)
        }
    }

    func test_arabic_checkpoint_generates_arabic_on_gpu() throws {
        let root = try directory("cohereArabic")
        let corpus = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ASRCorpus")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus.appendingPathComponent("manifest.json"))) as! [String: Any]
        let clip = (manifest["clips"] as! [[String: Any]]).first { $0["language"] as? String == "ar" }!
        let file = try AVAudioFile(forReading: corpus.appendingPathComponent(clip["filename"] as! String))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        try Device.withDefaultDevice(.gpu) {
            let model = try CohereTranscribeModel.fromDirectory(root)
            let result = model.generate(audio: MLXArray(samples), generationParameters: STTGenerateParameters(maxTokens: 256, language: "ar"))
            XCTAssertTrue(result.text.unicodeScalars.contains { (0x0600...0x06ff).contains($0.value) })
            print("COHERE_ARABIC_MAC_CHECK:", result.text)
        }
    }
}
