#if DEBUG
import SwiftUI
import AVFoundation
import MurmurSpeech

struct KeyboardStreamReplayView: View {
    @State private var status = "Preparing stream verification"
    var body: some View {
        VStack(spacing: 20) { Text("Keyboard stream verification").font(.title2); Text(status) }.padding().task {
            UIApplication.shared.isIdleTimerDisabled = true
            await run()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
    @MainActor private func run() async {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var report: [String: Any] = ["source": "FLEURS fixture, no microphone", "updatedAt": ISO8601DateFormatter().string(from: Date())]
        let accurate = ProcessInfo.processInfo.arguments.contains("--keyboard-replay-accurate")
        report["mode"] = accurate ? "accurate" : "fast"
        let session = BackgroundSpeechSession(choice: accurate ? .parakeet : .gigaam, mode: accurate ? .accurate : .fast, language: "ru", modelsRoot: StoragePaths.models)
        do {
            let file = try AVAudioFile(forReading: directory.appendingPathComponent("ASRCorpus/ru_ru-1642196827911660403.wav"))
            guard file.processingFormat.sampleRate == 16000,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw CocoaError(.fileReadCorruptFile) }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            try await session.prepare(); status = "Recognizing the known fixture"
            let result = try await session.transcribeOffline(samples)
            report["text"] = result.text; report["audioSeconds"] = result.seconds; report["speechWindows"] = result.speechWindows
            report["maximumSpeechProbability"] = result.maximumSpeechProbability; report["recognitionPasses"] = result.recognitionPasses
            report["maximumInputLevel"] = result.maximumInputLevel; report["passed"] = result.text.contains("каналов")
            status = result.text.isEmpty ? "Empty result" : result.text
        } catch { report["error"] = error.localizedDescription; status = error.localizedDescription }
        await session.close()
        if let data = try? JSONSerialization.data(withJSONObject: report) { try? data.write(to: directory.appendingPathComponent("keyboard-stream-replay.json"), options: .atomic) }
    }
}
#endif
