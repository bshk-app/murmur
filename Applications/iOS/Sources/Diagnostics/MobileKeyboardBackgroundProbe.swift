#if DEBUG
// Lab-only device probe. Audio for ASR comes from the pinned FLEURS corpus.
// The microphone tap counts frames to validate a real background recording session;
// it never saves microphone audio or sends it to recognition.
import SwiftUI
import AVFoundation
import Metal
import MurmurCore
import MurmurSpeech
import MurmurTranslation
import CoreFoundation

private final class ProbeCaptureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0
    func add(_ count: Int) { lock.lock(); value += count; lock.unlock() }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor final class MobileKeyboardBackgroundProbe: ObservableObject {
    @Published var status = "Preparing device probe…"
    private var report: [String: Any] = ["schema": 1, "purpose": "background keyboard feasibility", "audioSource": "FLEURS, not microphone"]
    private let engine = AVAudioEngine()
    private let capture = ProbeCaptureCounter()
    private let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var tapInstalled = false
    private let commandCounter = ProbeCaptureCounter()
    private var state: String { UIApplication.shared.applicationState == .background ? "background" : UIApplication.shared.applicationState == .active ? "active" : "inactive" }
    private func save(_ stage: String) {
        status = stage; report["stage"] = stage; report["applicationState"] = state
        report["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("keyboard-background-probe.json"), options: .atomic)
            if let shared = StoragePaths.shared { try? data.write(to: shared.appendingPathComponent("keyboard-background-probe.json"), options: .atomic) }
        }
    }
    func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        do {
            save("loading")
            let audio = try AVAudioFile(forReading: root.appendingPathComponent("ASRCorpus/ru_ru-1642196827911660403.wav"))
            guard audio.processingFormat.sampleRate == 16000,
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else { throw CocoaError(.fileReadCorruptFile) }
            try audio.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            report["audioSeconds"] = Double(samples.count) / 16000
            let args = ProcessInfo.processInfo.arguments
            let choice: SpeechModelChoice = args.contains("--probe-whisper") ? .whisper : args.contains("--probe-accurate") ? .parakeet : .gigaam
            let useANE = !args.contains("--probe-cpu")
            report["recognizer"] = choice.rawValue
            report["computeUnits"] = useANE ? "cpuAndNeuralEngine" : "cpuOnly"
            let lane = CoreMLSpeechLane(choice: choice, ane: useANE, modelsRoot: StoragePaths.models)
            try await lane.load(); save("recognizer-loaded")
            let vad = try await CoreMLVoiceActivity(); save("vad-loaded")
            let translator = TranslationSession(modelsRoot: StoragePaths.translation)
            try await translator.prepare(from: "ru", to: "en")
            try await translator.warmUp(from: "ru", to: "en")
            report["foregroundMetal"] = await Self.metalProbe()
            report["foregroundRecognition"] = try await recognize(lane, samples: samples)
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard allowed else { throw NSError(domain:"KeyboardProbe",code:1,userInfo:[NSLocalizedDescriptionKey:"Microphone permission denied"]) }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
            let input = engine.inputNode
            let counter = capture
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in counter.add(Int(buffer.frameLength)) }
            tapInstalled = true; try engine.start()
            save("awaiting-background")
            let deadline = Date().addingTimeInterval(120)
            while state != "background" && Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
            guard state == "background" else { throw NSError(domain:"KeyboardProbe",code:2,userInfo:[NSLocalizedDescriptionKey:"App never entered background"]) }
            let before = capture.read()
            try await Task.sleep(for: .seconds(3))
            if args.contains("--probe-keyboard-command") {
                save("checking-sustained-background")
                try await Task.sleep(for: .seconds(30))
                report["microphoneFramesBeforeKeyboardCommand"] = capture.read() - before
                let name = "app.bshk.murmur.probe." + UUID().uuidString
                let observer = Unmanaged.passUnretained(commandCounter).toOpaque()
                let center = CFNotificationCenterGetDarwinNotifyCenter()
                CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
                    if let observer { Unmanaged<ProbeCaptureCounter>.fromOpaque(observer).takeUnretainedValue().add(1) }
                }, name as CFString, nil, .deliverImmediately)
                defer { CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(name as CFString), nil) }
                report["commandName"] = name
                save("awaiting-keyboard-command")
                let commandDeadline = Date().addingTimeInterval(180)
                func receivedFile() -> Bool {
                    guard let url = StoragePaths.shared?.appendingPathComponent("keyboard-probe-command.txt") else { return false }
                    return (try? String(contentsOf: url, encoding: .utf8)) == name
                }
                while commandCounter.read() == 0 && !receivedFile() && Date() < commandDeadline { try await Task.sleep(for: .milliseconds(100)) }
                guard commandCounter.read() > 0 || receivedFile() else { throw NSError(domain: "KeyboardProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "No command received from the keyboard"]) }
                report["keyboardCommandReceived"] = true
                report["keyboardCommandViaFile"] = receivedFile()
            }
            save("testing-background")
            report["backgroundMetal"] = await Self.metalProbe(); save("metal-tested")
            report["backgroundRecognition"] = try await recognize(lane, samples: samples); save("recognition-tested")
            let quiet = try await vad.probabilities([Float](repeating: 0, count: 16000))
            let voice = try await vad.probabilities(samples)
            report["vad"] = ["state": state, "silenceMax": quiet.max() ?? -1, "speechMax": voice.max() ?? -1]
            save("vad-tested")
            let tick = Date()
            let recognized = (report["backgroundRecognition"] as? [String: Any])?["text"] as? String ?? ""
            let translated = try await translator.finish(recognized, from: "ru", to: "en")
            report["translation"] = ["state": state, "text": translated, "seconds": Date().timeIntervalSince(tick)]
            report["microphoneFramesInBackground"] = capture.read() - before
            report["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
            await lane.close()
            save("done")
        } catch {
            report["error"] = String(describing: error)
            save("failed")
        }
    }
    private func recognize(_ lane: CoreMLSpeechLane, samples: [Float]) async throws -> [String: Any] {
        let before = state, start = Date()
        let result = try await lane.transcribe(samples, language: "ru")
        return ["stateBefore": before, "stateAfter": state, "text": result, "seconds": Date().timeIntervalSince(start)]
    }
    private nonisolated static func metalProbe() async -> [String: Any] {
        await Task.detached {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let buffer = device.makeBuffer(length: 4096, options: .storageModePrivate),
                  let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return ["error": "Metal setup failed"] }
            blit.fill(buffer: buffer, range: 0..<4096, value: 1); blit.endEncoding()
            command.commit(); command.waitUntilCompleted()
            var result: [String: Any] = ["status": command.status.rawValue, "completed": command.status == .completed]
            if let error = command.error as NSError? { result["error"] = error.localizedDescription; result["code"] = error.code; result["domain"] = error.domain }
            return result
        }.value
    }
}

struct MobileKeyboardBackgroundProbeView: View {
    @StateObject private var probe = MobileKeyboardBackgroundProbe()
    var body: some View {
        VStack(spacing: 20) {
            Text("Keyboard background probe").font(.title)
            Text(probe.status).monospaced()
            Text("ASR uses a test file. The microphone session only counts frames; speak normally or stay silent.").font(.footnote)
        }.padding().task { await probe.run() }
    }
}

#endif
