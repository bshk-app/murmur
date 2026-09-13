import AVFoundation
import Foundation
import MurmurCore

public struct DirectSpeechResult: Sendable {
    public let utterances: [RecordedUtterance]
    public let duration: Double
    public var text: String { utterances.map(\.text).joined(separator: "\n") }
    public var translation: String { utterances.compactMap(\.translation).joined(separator: "\n") }
}

private final class DirectSpeechInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private let recording = RecordingAudioSink()
    private var stream: PCMFrameStream?
    private var samples = 0
    private var failure: (@Sendable (Error) -> Void)?

    func begin(stream: PCMFrameStream, recordingURL: URL?, failure: @escaping @Sendable (Error) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard self.stream == nil else { throw CocoaError(.fileWriteFileExists) }
        try recording.begin(url: recordingURL)
        self.stream = stream; self.failure = failure; samples = 0
    }

    func append(_ values: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard let stream else { return }
        do {
            try recording.append(values)
            try stream.yield(values)
            samples += values.count
        } catch {
            stream.finish(throwing: error)
            self.stream = nil
            failure?(error)
        }
    }

    func finish(throwing error: Error? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        let count = samples
        do { try recording.finish() } catch { failure?(error) }
        if let error { stream?.finish(throwing: error) } else { stream?.finish() }
        stream = nil; failure = nil; samples = 0
        return count
    }
}

private actor DirectUtteranceAccumulator {
    private var values: [RecordedUtterance] = []
    func append(_ value: RecordedUtterance) { values.append(value) }
    func result() -> [RecordedUtterance] { values }
}

/// Reusable, bounded direct speech-translation session. Models and microphone
/// stay prepared between keyboard utterances; PCM is accepted only while an
/// utterance is active.
@MainActor public final class DirectSpeechSession {
    public var onCapture: (@Sendable (Int, Float) -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    private nonisolated let processor: CanaryTranscriber
    private let gate = DirectSpeechInputGate()
    private var microphone: MicCapture?
    private var work: Task<[RecordedUtterance], Error>?
    private var capturedSamples = 0
    private var observers: [NSObjectProtocol] = []

    public init(computeMode: CanaryRuntime.ComputeMode = .foreground) {
        processor = CanaryTranscriber(computeMode: computeMode)
    }

    public func prepare(progress: @escaping @MainActor @Sendable (Progress) -> Void = { _ in }) async throws {
        try await processor.prepare(progress: progress)
    }

    public func arm(inputDeviceUID: String? = "built-in") throws {
        guard microphone == nil else { return }
        let capture = MicCapture(inputDeviceUID: inputDeviceUID, allowConcurrentPlayback: true)
        let gate = self.gate
        capture.onChunk = { gate.append($0) }
        capture.onCapture = { [weak self] count, _, peak, error in
            Task { @MainActor in
                guard let self else { return }
                self.onCapture?(count, peak)
                if let error { self.onError?(error) }
            }
        }
        try capture.start()
        microphone = capture
        observeInterruptions()
    }

    public func begin(source: String, target: String?, recordingURL: URL?,
        onProgress: @escaping @MainActor @Sendable (Int) async -> Void = { _ in },
        onBatch: @escaping @MainActor @Sendable (RecordedUtterance) async throws -> Void = { _ in }) throws {
        guard work == nil, CanaryRuntime.supportedLanguages.contains(source) else {
            throw CanaryRuntime.Failure.unsupportedLanguage(source)
        }
        if let target, !DirectSpeechTranslation.supports(source: source, target: target) {
            throw CanaryRuntime.Failure.unsupportedTranslation(source, target)
        }
        guard microphone != nil else { throw CancellationError() }
        let stream = PCMFrameStream(capacity: 128)
        capturedSamples = 0
        try gate.begin(stream: stream, recordingURL: recordingURL) { [weak self] error in
            Task { @MainActor in self?.onError?(error.localizedDescription) }
        }
        work = Task { [processor] in
            let accumulator = DirectUtteranceAccumulator()
            try await processor.process(source: source, target: target,
                nextFrame: { try await stream.nextFrame() },
                onProgress: { samples in await onProgress(samples) },
                onBatch: { range, result in
                    if target != nil, result.translatedText == nil { throw CocoaError(.coderValueNotFound) }
                    let value = RecordedUtterance(id: UInt64(range.lowerBound), startSample: range.lowerBound,
                        endSample: range.upperBound, text: result.sourceText, translation: result.translatedText, settled: true)
                    await accumulator.append(value)
                    try await onBatch(value)
                })
            return await accumulator.result()
        }
    }

    public func finish() async throws -> DirectSpeechResult {
        endInput()
        return try await waitForResult()
    }

    public func endInput() {
        guard work != nil else { return }
        microphone?.flushPending()
        capturedSamples = microphone?.atCaptureBoundary { gate.finish() } ?? gate.finish()
    }

    public func waitForResult() async throws -> DirectSpeechResult {
        guard let work else { throw CancellationError() }
        defer { self.work = nil }
        let utterances = try await work.value
        return DirectSpeechResult(utterances: utterances, duration: Double(capturedSamples) / 16_000)
    }

    public nonisolated func processFile(url: URL, source: String, target: String? = nil,
        onProgress: @escaping @Sendable (Double, Double) async -> Void = { _, _ in },
        onBatch: @escaping @Sendable (RecordedUtterance) async throws -> Void = { _ in }) async throws {
        guard CanaryRuntime.supportedLanguages.contains(source) else { throw CancellationError() }
        if let target, !DirectSpeechTranslation.supports(source: source, target: target) {
            throw CanaryRuntime.Failure.unsupportedTranslation(source, target)
        }
        try await processor.processFile(url: url, source: source, target: target,
            onProgress: { seconds, total in await onProgress(seconds, total) },
            onBatch: { range, result in
                let value = RecordedUtterance(id: UInt64(range.lowerBound), startSample: range.lowerBound,
                    endSample: range.upperBound, text: result.sourceText, translation: result.translatedText, settled: true)
                try await onBatch(value)
            })
    }

    public func cancelUtterance() async {
        work?.cancel()
        microphone?.flushPending()
        _ = microphone?.atCaptureBoundary { gate.finish(throwing: CancellationError()) } ?? gate.finish(throwing: CancellationError())
        _ = try? await work?.value
        work = nil
    }

    public func disarm() {
        guard work == nil else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        _ = microphone?.stop(); microphone = nil
    }

    public func close() async {
        await cancelUtterance()
        disarm()
        await processor.close()
    }

    private func observeInterruptions() {
        #if os(iOS)
        guard observers.isEmpty else { return }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if notification.name == AVAudioSession.interruptionNotification,
                   (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.began.rawValue { return }
                Task { @MainActor in self?.onError?("audio interruption") }
            })
        }
        #endif
    }
}
