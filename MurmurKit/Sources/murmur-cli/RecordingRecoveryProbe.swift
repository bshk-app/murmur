import Foundation
import AVFoundation
#if os(iOS)
import MurmurCore
import MurmurSpeech
import MurmurTranslation
#else
import MurmurKit
#endif

@MainActor private final class RecordingProbeState {
    var transcript = RecordingTranscript()
    let base: VoiceNote
    var firstSettled: String?
    var lastSave = Date.distantPast
    var lastLog = Date.distantPast
    init(_ base: VoiceNote) { self.base = base }
    func receive(_ snapshot: CaptionSnapshot) -> VoiceNote? {
        transcript.apply(snapshot)
        if firstSettled == nil { firstSettled = transcript.utterances.first(where: \.settled)?.text }
        if Date().timeIntervalSince(lastLog) > 30 {
            lastLog = Date()
            FileHandle.standardError.write(Data("recording-replay: phrases=\(transcript.utterances.count), characters=\(transcript.text.count)\n".utf8))
        }
        guard Date().timeIntervalSince(lastSave) > 1 else { return nil }
        lastSave = Date(); return note(complete: false)
    }
    func translations(_ values: [UtteranceTranslation]) { transcript.applyTranslations(values) }
    func finish(_ final: String, samples: Int) { transcript.finish(fallback: final, endSample: samples) }
    func note(complete: Bool) -> VoiceNote {
        var note = base
        note.text = transcript.text; note.translation = transcript.translatedText.isEmpty ? nil : transcript.translatedText
        note.utterances = transcript.utterances; note.captureRevision = transcript.revision; note.transcriptionComplete = complete
        return note
    }
}

private actor RetryProbeState {
    let original: VoiceNote
    let checkpoint: URL
    var segments: [AudioFileSegment] = []
    init(original: VoiceNote, checkpoint: URL) { self.original = original; self.checkpoint = checkpoint }
    func append(_ segment: AudioFileSegment) throws {
        segments.append(segment)
        try JSONEncoder().encode(segments).write(to: checkpoint, options: .atomic)
    }
    func note(complete: Bool) -> VoiceNote {
        var result = original
        result.text = segments.map(\.text).joined(separator: "\n\n")
        result.translation = nil; result.targetLanguage = nil; result.transcriptionComplete = complete
        result.utterances = segments.enumerated().map { .init(id: UInt64($0.offset + 1), startSample: $0.element.startSample, endSample: $0.element.endSample, text: $0.element.text, settled: true) }
        return result
    }
}

private actor CancellationProbeCounter {
    var count = 0
    func increment() { count += 1 }
}

enum RecordingRecoveryProbe {
    @MainActor static func run(source: [Float], seconds: Int, language: String, target: String, modelsRoot: URL, output: URL, qualityRoots: [URL] = []) async throws {
        guard !source.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let samples = (0..<(seconds * 16_000)).map { source[$0 % source.count] }
        let notesRoot = output.deletingLastPathComponent().appendingPathComponent("Notes")
        let repository = NoteRepository(directory: notesRoot)
        let audio = RecordedAudio()
        let audioURL = try audio.url(in: notesRoot.appendingPathComponent("Recordings"))
        let writer = try PCMRecordingWriter(url: audioURL)
        var base = VoiceNote(id: audio.recordingID, text: "", sourceLanguage: language, targetLanguage: target, duration: Double(seconds), model: "recording recovery probe")
        base.audio = audio; base.transcriptionComplete = false
        try await repository.save(base)
        let observed = RecordingProbeState(base)
        let speech = SpeechSession(quantization: "int4", ane: true, memoryLimit: 3_500_000_000, corrector: language == "ru" ? .gigaam : .parakeet, modelsRoot: modelsRoot)
        let translator = TranslationSession(modelsRoot: modelsRoot, qualityModelsRoots: qualityRoots)
        try await speech.load(mode: .accurate); try await speech.warmUp(mode: .accurate, language: language)
        try await translator.prepare(from: language, to: target); try await translator.warmUp(from: language, to: target)
        speech.onSnapshot = { snapshot, _, _, _ in
            Task { @MainActor in
                if let note = observed.receive(snapshot) { try await repository.saveProgress(note) }
                await translator.update(snapshot, from: language, to: target, onUpdate: { _ in }, onFailure: { _ in },
                    onSegments: { values in Task { @MainActor in observed.translations(values) } })
            }
        }
        var writeError: Error?
        let result = await speech.transcribeOffline(samples, mode: .accurate, language: language) { chunk in
            do { try writer.append(chunk) } catch { writeError = error }
        }
        try writer.finish(); if let writeError { throw writeError }
        _ = observed.receive(await speech.snapshot())
        observed.finish(result.text, samples: samples.count)
        try await repository.save(observed.note(complete: true))
        try await translator.finishUtterances(observed.transcript.utterances, from: language, to: target) { value in
            await observed.translations([value])
        }
        let original = observed.note(complete: true)
        try await repository.save(original)
        await speech.close(); await translator.unload()

        let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        var difference: Float = 0
        if Int(buffer.frameLength) == samples.count, let channel = buffer.floatChannelData?[0] {
            for index in samples.indices { difference = max(difference, abs(channel[index] - samples[index])) }
        } else { difference = 1 }

        let retry = RetryProbeState(original: original, checkpoint: output.deletingLastPathComponent().appendingPathComponent("retry-checkpoint.json"))
        let previousVersion = TranscriptVersion(note: original)
        let transcriber = AudioFileTranscriber(choice: language == "ru" ? .gigaam : .parakeet, modelsRoot: modelsRoot)
        try await transcriber.run(url: audioURL, language: language, onReady: {}, onProgress: { _, _ in }, onSegment: { segment, _ in
            try await retry.append(segment)
            try await repository.saveTranscription(await retry.note(complete: false), previousVersion: previousVersion)
        })
        await transcriber.close()
        let beforeReplacement = try await repository.all().first { $0.id == original.id }
        try await repository.saveTranscription(await retry.note(complete: true), previousVersion: previousVersion)
        let reopened = try await NoteRepository(directory: notesRoot).all().first { $0.id == original.id }
        let keptBeginning = observed.firstSettled.map { original.text.hasPrefix($0) } ?? false
        let keptPrior = reopened?.transcriptVersions?.first?.text == original.text && reopened?.transcriptVersions?.first?.translation == original.translation
        let cancellationCounter = CancellationProbeCounter()
        var cancellationObserved = false
        try await translator.prepare(from: language, to: target)
        do {
            try await translator.finishUtterances(Array((original.utterances ?? []).prefix(2)), from: language, to: target) { _ in
                await cancellationCounter.increment(); await translator.cancel()
            }
        } catch is CancellationError { cancellationObserved = true }
        await translator.unload()
        let cancellationCallbacks = await cancellationCounter.count
        let cancellationStops = cancellationObserved && cancellationCallbacks == 1
        let passed = keptBeginning && difference < 0.0001 && beforeReplacement?.text == original.text && keptPrior && reopened?.text.isEmpty == false && FileManager.default.fileExists(atPath: audioURL.path) && cancellationStops
        let report: [String: Any] = ["passed": passed, "source": "160-second Finnish source repeated for a bounded recording test", "audioSeconds": Double(file.length) / file.processingFormat.sampleRate,
            "audioSamples": file.length, "expectedSamples": samples.count, "maximumPCMError": difference,
            "firstTranscriptCharacters": original.text.count, "firstTranslationCharacters": original.translation?.count ?? 0,
            "firstUtterances": original.utterances?.count ?? 0, "beginningRetained": keptBeginning,
            "retryTranscriptCharacters": reopened?.text.count ?? 0, "previousVersionRetained": keptPrior,
            "previousResultUnchangedUntilRetryCompleted": beforeReplacement?.text == original.text,
            "audioRetainedAfterRetry": FileManager.default.fileExists(atPath: audioURL.path), "recordingURL": audioURL.path,
            "cancellationStopsAfterFirstUtterance": cancellationStops,
            "pacedReplayWallSeconds": result.wallSeconds]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        print("Recording recovery report: \(output.path); passed=\(passed)")
        if !passed { throw CocoaError(.fileReadCorruptFile) }
    }
}
