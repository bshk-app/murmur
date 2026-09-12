import Foundation
import AVFoundation

@main struct QualificationChecks {
    static func rejects(_ check: () throws -> Void) {
        do { try check(); fatalError("Expected validation failure") } catch {}
    }
    static func main() async throws {
        precondition(CanaryQualificationRuntime.supportedLanguages.count == 25)
        for language in CanaryQualificationRuntime.supportedLanguages { try CanaryQualificationRuntime.validateLanguage(language) }
        rejects { try CanaryQualificationRuntime.validateLanguage("nb") }
        rejects { try CanaryQualificationRuntime.validateLanguage("EN") }
        rejects { try CanaryQualificationRuntime.validateAudio([]) }
        rejects { try CanaryQualificationRuntime.validateAudio([Float.nan]) }
        rejects { try CanaryQualificationRuntime.validateAudio([Float.infinity]) }
        rejects { try CanaryQualificationRuntime.validateAudio([1.01]) }
        rejects { try CanaryQualificationRuntime.validateAudio(Array(repeating: 0, count: 240001)) }
        try CanaryQualificationRuntime.validateAudio(Array(repeating: 0, count: 240000))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var pieces = Array(repeating: "unused", count: 16384)
        for (index, language) in CanaryQualificationRuntime.supportedLanguages.sorted().enumerated() { pieces[100 + index] = "<|\(language)|>" }
        try JSONSerialization.data(withJSONObject: pieces).write(to: temporary)
        let tokenizer = try CanaryQualificationTokenizer(url: temporary)
        for language in CanaryQualificationRuntime.supportedLanguages {
            let prompt = try tokenizer.prompt(source: language, target: language)
            precondition(prompt.count == 10 && prompt[4] == prompt[5])
            precondition(pieces[Int(prompt[4])] == "<|\(language)|>")
            precondition(prompt.enumerated().allSatisfy { [4, 5].contains($0.offset) || $0.element == CanaryQualificationConfig.promptEnTranscribePnc[$0.offset] })
        }
        rejects { _ = try tokenizer.prompt(source: "nb", target: "nb") }
        precondition(canaryQualificationFloat16BitsToFloat(0x3800) == 0.5)
        print("Canary short-window, language, PCM, prompt and float16 checks passed")
        guard CommandLine.arguments.count == 4 else { return }
        let modelDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
        let audioURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let language = CommandLine.arguments[3]
        let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        precondition(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        try CanaryQualificationRuntime.validateAudio(samples)
        let runtime = try await CanaryQualificationRuntime(modelsDirectory: modelDirectory, sourceLanguage: language)
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await runtime.transcribe(audio: samples)
        precondition(!result.isEmpty)
        print("ASR \(language), samples=\(samples.count), seconds=\(ProcessInfo.processInfo.systemUptime-start): \(result)")
    }
}
