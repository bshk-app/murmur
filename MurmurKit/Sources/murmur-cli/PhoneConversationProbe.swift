import Foundation
import MurmurKit

/// Real phone speech/translation engines, file input at microphone pace. No microphone.
enum PhoneConversationProbe {
    private final class Observations: @unchecked Sendable {
        let lock = NSLock()
        var latest = CaptionSnapshot(revision: 0, confirmed: [], provisional: "")
        var firstSample: Int?
        var lastLog = Date.distantPast
        var translationCharacters = 0
        func record(_ snapshot: CaptionSnapshot) {
            lock.lock(); defer { lock.unlock() }
            latest = snapshot
            if let first = snapshot.confirmed.first?.startSample { firstSample = min(firstSample ?? first, first) }
            if Date().timeIntervalSince(lastLog) >= 30 {
                lastLog = Date()
                let seconds = Double(snapshot.confirmed.last?.endSample ?? 0) / 16000
                FileHandle.standardError.write(Data("phone-replay: \(Int(seconds))s; phrases=\(snapshot.confirmed.count); firstSample=\(snapshot.confirmed.first?.startSample ?? -1)\n".utf8))
            }
        }
        func translated(_ text: String) { lock.lock(); translationCharacters = text.count; lock.unlock() }
    }
    @MainActor static func run(samples source: [Float], seconds: Int, mode: DictationMode, language: String, target: String, modelsRoot: URL, output: URL) async throws {
        let count = seconds * 16000
        guard !source.isEmpty, count > 0 else { throw CocoaError(.fileReadCorruptFile) }
        var audio = [Float](); audio.reserveCapacity(count)
        while audio.count < count { audio.append(contentsOf: source.prefix(min(source.count, count - audio.count))) }
        let observed = Observations()
        let speech = SpeechSession(quantization: "int4", ane: true, memoryLimit: 3_500_000_000, corrector: language == "ru" ? .gigaam : .parakeet, modelsRoot: modelsRoot)
        let translator = TranslationSession(modelsRoot: modelsRoot)
        FileHandle.standardError.write(Data("Preparing real phone engines for \(language) → \(target), \(seconds)s\n".utf8))
        try await speech.load(mode: mode)
        try await speech.warmUp(mode: mode, language: language)
        try await translator.prepare(from: language, to: target)
        try await translator.warmUp(from: language, to: target)
        speech.onSnapshot = { snapshot, _, _, _ in
            observed.record(snapshot)
            Task {
                await translator.update(snapshot, from: language, to: target,
                    onUpdate: { observed.translated($0) },
                    onFailure: { message in FileHandle.standardError.write(Data("translation-error: \(message)\n".utf8)) })
            }
        }
        let result = await speech.transcribeOffline(audio, mode: mode, language: language)
        let translation = try await translator.finish(result.text, from: language, to: target)
        let last = observed.latest
        let retained = observed.firstSample != nil && observed.firstSample == last.confirmed.first?.startSample
        let report: [String: Any] = ["source": "eo9SkUsg4qg, 160-second clip repeated for a bounded load test", "requestedAudioSeconds": seconds,
            "audioSeconds": result.audioSeconds, "wallSeconds": result.wallSeconds, "computeSeconds": result.computeSeconds,
            "mode": mode.rawValue, "sourceLanguage": language, "targetLanguage": target,
            "confirmedPhrases": last.confirmed.count, "transcriptCharacters": result.text.count,
            "translationCharacters": translation.count, "earliestSpeechSample": observed.firstSample ?? -1,
            "finalFirstSpeechSample": last.confirmed.first?.startSample ?? -1, "beginningRetained": retained,
            "passed": retained && !result.text.isEmpty && !translation.isEmpty]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        await speech.close(); await translator.unload()
        print("Phone conversation report: \(output.path)")
    }
}
