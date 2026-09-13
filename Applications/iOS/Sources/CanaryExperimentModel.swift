import AVFoundation
import UIKit
import Foundation
import Observation
import MurmurCore
import MurmurSpeech
import MurmurTranslation

@MainActor @Observable final class CanaryExperimentModel {
    enum Phase { case idle, preparing, recording, processing, cancelling, finished, failed }
    var source = "ru" { didSet { if source != oldValue { clearDisplayedResult() } } }
    var target = "en" { didSet { if target != oldValue { clearDisplayedResult() } } }
    var translateEnabled = true { didSet { if translateEnabled != oldValue { clearDisplayedResult() } } }
    var directTranslationEnabled = false { didSet { if directTranslationEnabled != oldValue { clearDisplayedResult() } } }
    private(set) var phase = Phase.idle
    private(set) var transcript = ""
    private(set) var translation = ""
    private(set) var completedBatches = 0
    private(set) var processedSeconds = 0.0
    private(set) var totalSeconds: Double?
    private(set) var recordedSeconds = 0.0
    private(set) var progress: Double?
    private(set) var inputName: String?
    private(set) var hasLoadedModels = false
    var error: String?
    var isRecording: Bool { phase == .recording }
    var activeNoteID: UUID? { operationActive ? note?.id : nil }
    private var operationActive = false
    private var closingCount = 0
    var isBusy: Bool { operationActive || closingCount > 0 }
    @ObservationIgnored private let session = DirectSpeechSession()
    @ObservationIgnored private let repository = NoteRepository(directory: StoragePaths.notes)
    @ObservationIgnored private var textEngine: TextTranslationSession?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var idleHeld = false
    @ObservationIgnored private var note: VoiceNote?
    @ObservationIgnored private var route: (source: String, target: String?, direct: Bool) = ("ru", nil, false)

    private enum Failure: Error, LocalizedError {
        case memory, microphone, invalidLanguage, behind, processing
        var errorDescription: String? {
            switch self {
            case .memory: return L10n.text("This device does not have enough memory for direct speech processing.")
            case .microphone: return L10n.text("Allow microphone access in Settings to record a note.")
            case .invalidLanguage: return L10n.text("This language is unavailable in the selected mode.")
            case .behind: return L10n.text("Processing fell behind. The recording and partial results were saved.")
            case .processing: return L10n.text("The recording could not be processed. Available audio and text were saved.")
            }
        }
    }

    func startRecording(prepareExclusive: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        let token = begin()
        work = Task { [self] in
            do {
                try check(token)
                let allowed = await withCheckedContinuation { reply in
                    SpeechSession.requestMicrophoneAccess { reply.resume(returning: $0) }
                }
                guard allowed else { throw Failure.microphone }
                try await prepare(token, exclusive: prepareExclusive)
                let audio = RecordedAudio()
                let url = try audio.url(in: StoragePaths.recordings)
                try await createNote(audio: audio, name: nil, recording: true, token: token)
                try check(token)
                session.onCapture = { [weak self] count, _ in Task { @MainActor in
                    guard let self, self.generation == token, self.operationActive, self.isRecording else { return }
                    self.recordedSeconds += Double(count) / 16_000
                } }
                session.onError = { [weak self] _ in Task { @MainActor in
                    guard let self, self.generation == token, self.operationActive, self.isRecording else { return }
                    self.stopRecording()
                } }
                guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
                try session.arm()
                try session.begin(source: route.source, target: route.direct ? route.target : nil, recordingURL: url,
                    onProgress: { [weak self] samples in await self?.updateProgress(Double(samples) / 16_000, total: nil, token: token) },
                    onBatch: { [weak self] utterance in try await self?.accept(utterance, token: token) })
                phase = .recording
                holdIdleTimer()
                let result = try await session.waitForResult()
                recordedSeconds = result.duration; totalSeconds = result.duration
                try check(token)
                try await finishNote(complete: true)
                phase = .finished
            } catch { await failed(error, token: token) }
            await release(token: token)
        }
    }

    func processFile(_ url: URL, prepareExclusive: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        let token = begin()
        work = Task { [self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var pendingCopy: URL?
            do {
                try await prepare(token, exclusive: prepareExclusive)
                let audio = RecordedAudio(filename: url.lastPathComponent, isMicrophoneRecording: false)
                let destination = try audio.url(in: StoragePaths.recordings)
                pendingCopy = destination
                try await Task.detached {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                }.value
                try check(token)
                inputName = url.lastPathComponent
                try await createNote(audio: audio, name: inputName, recording: false, token: token)
                pendingCopy = nil
                phase = .processing
                holdIdleTimer()
                try await session.processFile(url: destination, source: route.source, target: route.direct ? route.target : nil,
                    onProgress: { [weak self] seconds, total in await self?.updateProgress(seconds, total: total, token: token) },
                    onBatch: { [weak self] utterance in try await self?.accept(utterance, token: token) })
                try check(token)
                try await finishNote(complete: true)
                phase = .finished
            } catch {
                if let pendingCopy, note == nil { try? FileManager.default.removeItem(at: pendingCopy.deletingLastPathComponent()) }
                await failed(error, token: token)
            }
            await release(token: token)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        phase = .processing
        session.endInput()
    }
    func cancel() {
        guard operationActive else { return }
        phase = .cancelling
        work?.cancel()
        Task { await session.cancelUtterance() }
    }
    func close() async {
        closingCount += 1
        defer { closingCount -= 1 }
        cancel()
        await work?.value
        await session.close()
        await textEngine?.unload(); textEngine = nil
        hasLoadedModels = false
        restoreIdleTimer()
    }
    private func begin() -> UUID {
        generation = UUID(); operationActive = true; phase = .preparing; error = nil
        transcript = ""; translation = ""; completedBatches = 0
        processedSeconds = 0; recordedSeconds = 0; totalSeconds = nil; progress = nil; inputName = nil
        note = nil
        let destination = translateEnabled && source != target ? target : nil
        route = (source, destination, destination.map { directTranslationEnabled && DirectSpeechTranslation.supports(source: source, target: $0) } ?? false)
        return generation
    }
    private func prepare(_ token: UUID, exclusive: @MainActor () async throws -> Void) async throws {
        try check(token)
        guard CanaryRuntime.supportedLanguages.contains(route.source), route.target.map(LanguagePair.qualityLanguages.contains) ?? true else { throw Failure.invalidLanguage }
        #if os(iOS) && !targetEnvironment(simulator)
        // Conservative experimental floor: the 4 GiB XS exceeded its process limit.
        guard ProcessInfo.processInfo.physicalMemory >= 5 * 1_024 * 1_024 * 1_024 else { throw Failure.memory }
        #endif
        try check(token)
        try await exclusive()
        try check(token)
        holdIdleTimer()
        try await session.prepare { [weak self] value in
            guard let self, self.generation == token else { return }
            self.progress = value.totalUnitCount > 0 ? value.fractionCompleted : nil
        }
        try check(token)
        hasLoadedModels = true; progress = nil
        if let target = route.target, !route.direct {
            let engine = TextTranslationSession(modelsRoot: StoragePaths.translation)
            textEngine = engine
            try await engine.prepare(from: route.source, to: target) { [weak self] value in
                guard let self, self.generation == token else { return }; self.progress = value
            }
            try check(token); progress = nil
        }
    }
    private func createNote(audio: RecordedAudio, name: String?, recording: Bool, token: UUID) async throws {
        try check(token)
        var value = VoiceNote(text: "", sourceLanguage: route.source, targetLanguage: route.target,
                              duration: 0, model: route.direct ? "direct-speech-translation" : "experimental-speech-recognition")
        value.audio = audio; value.sourceFileName = name; value.captureClosed = !recording
        value.transcriptionComplete = false; value.translationIncomplete = route.target != nil
        value.utterances = []
        note = value
        try await repository.save(value)
        try check(token)
    }
    private func accept(_ utterance: RecordedUtterance, token: UUID) async throws {
        try check(token)
        guard var value = note else { throw CocoaError(.fileNoSuchFile) }
        guard utterance.startSample >= (value.utterances?.last?.endSample ?? 0) else { throw CocoaError(.fileReadCorruptFile) }
        value.utterances?.append(utterance)
        value.text = value.utterances?.map(\.text).joined(separator: "\n") ?? ""
        value.translation = route.target == nil ? nil : value.utterances?.compactMap(\.translation).joined(separator: "\n")
        value.duration = max(value.duration, Double(utterance.endSample) / 16_000)
        try await repository.save(value)
        // Once the database accepted this batch, cancellation must not restore
        // an older in-memory note and erase the newly persisted source text.
        note = value
        try check(token)
        transcript = value.text; translation = value.translation ?? ""
        completedBatches += 1
        if let target = route.target, !route.direct {
            guard let textEngine else { throw CocoaError(.fileReadCorruptFile) }
            let translated = try await textEngine.translate(utterance.text, from: route.source, to: target)
            try check(token)
            guard var utterances = value.utterances, let index = utterances.indices.last else { throw CocoaError(.fileReadCorruptFile) }
            utterances[index].translation = translated
            value.utterances = utterances
            value.translation = value.utterances?.compactMap(\.translation).joined(separator: "\n")
            try await repository.save(value)
            note = value
            try check(token)
            translation = value.translation ?? ""
        } else if route.target != nil, utterance.translation == nil {
            throw CocoaError(.coderValueNotFound)
        }
    }
    private func updateProgress(_ seconds: Double, total: Double?, token: UUID) {
        guard generation == token, !Task.isCancelled else { return }
        processedSeconds = seconds
        if let total {
            totalSeconds = total; recordedSeconds = total
        }
        if let totalSeconds, totalSeconds > 0 { progress = min(1, max(0, seconds / totalSeconds)) }
    }
    private func finishNote(complete: Bool) async throws {
        guard var value = note else { return }
        value.duration = max(value.duration, max(recordedSeconds, processedSeconds))
        value.captureClosed = true; value.transcriptionComplete = complete
        value.translationIncomplete = route.target != nil && !complete
        try await repository.save(value)
        note = value
    }
    private func failed(_ failure: Error, token: UUID) async {
        guard generation == token else { return }
        #if DEBUG
        NSLog("Canary operation failed: %@", String(describing: failure as NSError))
        #endif
        do { try await finishNote(complete: false) } catch { self.error = error.localizedDescription }
        transcript = note?.text ?? transcript; translation = note?.translation ?? translation
        completedBatches = note?.utterances?.count ?? completedBatches
        if failure is CancellationError || Task.isCancelled { phase = .idle }
        else {
            if let known = failure as? Failure { error = known.localizedDescription }
            else if failure is PCMFrameStream.StreamError { error = Failure.behind.localizedDescription }
            else { error = Failure.processing.localizedDescription }
            phase = .failed
        }
    }
    private func release(token: UUID) async {
        await session.close(); await textEngine?.unload(); textEngine = nil
        if generation == token { hasLoadedModels = false; progress = phase == .finished ? 1 : nil; work = nil; operationActive = false }
        restoreIdleTimer()
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }
    private func clearDisplayedResult() {
        guard !isBusy else { return }
        transcript = ""; translation = ""; completedBatches = 0
        processedSeconds = 0; recordedSeconds = 0; totalSeconds = nil; inputName = nil
        error = nil; phase = .idle
    }
    private func holdIdleTimer() { idleHeld = true; UIApplication.shared.isIdleTimerDisabled = true }
    private func restoreIdleTimer() {
        guard idleHeld else { return }
        idleHeld = false; UIApplication.shared.isIdleTimerDisabled = false
    }
}
