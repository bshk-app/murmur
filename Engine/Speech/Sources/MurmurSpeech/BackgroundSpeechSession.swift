import Foundation
import MurmurCore
import FluidAudio

public struct BackgroundSpeechResult: Sendable {
    public let text: String
    public let seconds: Double
    public let speechWindows: Int
    public let maximumSpeechProbability: Float
    public let maximumInputLevel: Float
    public let recognitionPasses: Int
    public let snapshot: CaptionSnapshot
}

/// One Core ML recognizer and a CPU Silero detector. The microphone stays active
/// between utterances, but idle samples are immediately discarded.
@MainActor public final class BackgroundSpeechSession {
    public var onText: (@Sendable (UUID, String) -> Void)?
    public var onSnapshot: (@Sendable (UUID, CaptionSnapshot) -> Void)?
    public var onError: (@Sendable (String) -> Void)?
    public var onLevel: (@Sendable (Float) -> Void)?
    public var onRecordingError: (@Sendable (String) -> Void)?
    private let recording = RecordingAudioSink()
    private let processor: BackgroundSpeechProcessor
    private var mic: MicCapture?
    private var continuation: AsyncStream<Event>.Continuation?
    private var consumer: Task<Void, Never>?
    private enum Event: @unchecked Sendable {
        case audio([Float])
        case begin(UUID, CheckedContinuation<Void, Error>)
        case finish(CheckedContinuation<BackgroundSpeechResult, Error>)
        case discard(CheckedContinuation<Void, Never>)
    }
    public init(choice: SpeechModelChoice, mode: KeyboardRecognitionMode, language: String, modelsRoot: URL) {
        processor = BackgroundSpeechProcessor(choice: choice, mode: mode, language: language, root: modelsRoot)
    }
    public func prepare() async throws {
        try await processor.load()
    }
    /// Replay through the identical segmentation/recognition path without
    /// opening a microphone. Used to distinguish capture from model failures.
    public func transcribeOffline(_ audio: [Float]) async throws -> BackgroundSpeechResult {
        guard mic == nil else { throw CancellationError() }
        try await processor.begin(UUID())
        for offset in stride(from: 0, to: audio.count, by: 1536) {
            try Task.checkCancellation()
            await processor.step(Array(audio[offset..<min(audio.count, offset + 1536)]))
        }
        return try await processor.finish()
    }
    public func arm() throws {
        let stream = AsyncStream<Event>(bufferingPolicy: .bufferingOldest(128)) { continuation = $0 }
        let textCallback = onText, errorCallback = onError, snapshotCallback = onSnapshot
        consumer = Task { [processor] in
            await processor.callbacks(text: textCallback, error: errorCallback, snapshot: snapshotCallback)
            for await event in stream {
                switch event {
                case .audio(let audio): await processor.step(audio)
                case .begin(let id, let reply):
                    do { try await processor.begin(id); reply.resume() } catch { reply.resume(throwing: error) }
                case .finish(let reply):
                    do { reply.resume(returning: try await processor.finish()) } catch { reply.resume(throwing: error) }
                case .discard(let reply): await processor.discard(); reply.resume()
                }
            }
        }
        let input = MicCapture(inputDeviceUID: "built-in", allowConcurrentPlayback: true)
        let sender = continuation
        let level = onLevel
        let recording = self.recording, recordingError = onRecordingError
        input.onCapture = { _, _, peak, error in
            level?(peak)
            if let error { errorCallback?(error) }
        }
        input.onChunk = { samples in
            do { try recording.append(samples) } catch { recordingError?(error.localizedDescription) }
            if case .dropped = sender?.yield(.audio(samples)) { errorCallback?("Audio processing fell behind. Please start again.") }
        }
        do { try input.start(); mic = input }
        catch { continuation?.finish(); throw error }
    }
    public func begin(_ id: UUID, recordingURL: URL? = nil) async throws {
        mic?.flushPending()
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            guard let continuation, let mic else { reply.resume(throwing: CancellationError()); return }
            do {
                try mic.atCaptureBoundary {
                    try recording.begin(url: recordingURL)
                    if case .enqueued = continuation.yield(.begin(id, reply)) {} else { reply.resume(throwing: CancellationError()) }
                }
            } catch { reply.resume(throwing: error) }
        }
    }
    public func finish() async throws -> BackgroundSpeechResult {
        mic?.flushPending()
        try mic?.atCaptureBoundary { try recording.finish() }
        return try await withCheckedThrowingContinuation { reply in
            guard let continuation else { reply.resume(throwing: CancellationError()); return }
            if case .enqueued = continuation.yield(.finish(reply)) {} else { reply.resume(throwing: CancellationError()) }
        }
    }
    public func discard() async {
        mic?.flushPending()
        try? mic?.atCaptureBoundary { try recording.finish() }
        await withCheckedContinuation { reply in
            guard let continuation else { reply.resume(); return }
            if case .enqueued = continuation.yield(.discard(reply)) {} else { reply.resume() }
        }
    }
    public func close() async {
        _ = mic?.stop(); mic = nil
        do { try recording.finish() } catch { onRecordingError?(error.localizedDescription) }
        continuation?.finish(); continuation = nil
        await processor.shutdown()
        await consumer?.value; consumer = nil
    }
}

private final class BackgroundLiveBuffer {
    var audio: [Float] = []
    var text = ""
    var probability: Float = 0
    var epoch = 0
    var open = false
    var lastRequestedSample = 0
    var finalRequests: [(UInt64, [Float], String)] = []
}

/// The input stream owns ordering. Core ML predictions suspend this actor, so
/// CPU VAD keeps consuming audio while one ASR prediction runs. Final phrases
/// are never coalesced; only superseded provisional requests are discarded.
private actor BackgroundSpeechProcessor {
    private let lane: CoreMLSpeechLane
    private let language: String
    private let mode: KeyboardRecognitionMode
    private var vad: VadManager?
    private var vadState = VadStreamState.initial()
    private var buffer = BackgroundLiveBuffer()
    private var policy: CaptionEngine?
    private var tail: [Float] = []
    private var confirmed: [UInt64: String] = [:]
    private var draft: (epoch: Int, samples: [Float])?
    private var finals: [(UInt64, [Float])] = []
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var utterance: UUID?
    private var samples = 0
    private var speechWindows = 0
    private var maxProbability: Float = 0
    private var maxInput: Float = 0
    private var recognitionPasses = 0
    private var recording = false
    private var closed = false
    private var failure: String?
    private var lastText = ""
    private var textRevision: UInt64 = 0
    private var onText: (@Sendable (UUID, String) -> Void)?
    private var onError: (@Sendable (String) -> Void)?
    private var onSnapshot: (@Sendable (UUID, CaptionSnapshot) -> Void)?
    init(choice: SpeechModelChoice, mode: KeyboardRecognitionMode, language: String, root: URL) {
        lane = CoreMLSpeechLane(choice: choice, modelsRoot: root); self.mode = mode; self.language = language
    }
    func load() async throws {
        try await lane.load()
        vad = try await VadManager(config: VadConfig(computeUnits: .cpuOnly))
        _ = try await lane.transcribe([Float](repeating: 0, count: 16_000), language: language)
        _ = try await vad?.process([Float](repeating: 0, count: 16_000))
    }
    func callbacks(text: (@Sendable (UUID, String) -> Void)?, error: (@Sendable (String) -> Void)?, snapshot: (@Sendable (UUID, CaptionSnapshot) -> Void)?) { onText = text; onError = error; onSnapshot = snapshot }
    func begin(_ id: UUID) throws {
        guard !closed, vad != nil else { throw CancellationError() }
        discard()
        utterance = id; recording = true; samples = 0; lastText = ""; textRevision = 0; failure = nil
        speechWindows = 0; maxProbability = 0; maxInput = 0; recognitionPasses = 0
        buffer = BackgroundLiveBuffer(); let b = buffer
        policy = CaptionEngine(live: .init(begin: { b.epoch += 1; b.open = true; b.audio = []; b.text = ""; b.lastRequestedSample = 0 },
            step: { b.audio.append(contentsOf: $0) }, text: { b.text }, finish: { b.open = false }),
            isSpeech: { _ in b.probability >= 0.5 }, batch: { _, _ in "" }, maxEpochSeconds: mode == .fast ? 8 : 16,
            enqueueCorrection: { id, _, audio in b.finalRequests.append((id, audio, b.text)) })
    }
    func step(_ audio: [Float]) async {
        guard recording, !closed, let vad else { return }
        let token = generation
        samples += audio.count; tail.append(contentsOf: audio)
        maxInput = max(maxInput, audio.map(abs).max() ?? 0)
        // FluidAudio's Core ML export consumes 4096 samples, unlike the
        // 512-sample MLX export used by ordinary foreground dictation.
        while tail.count >= VadManager.chunkSize {
            let frame = Array(tail.prefix(VadManager.chunkSize)); tail.removeFirst(VadManager.chunkSize)
            do {
                let result = try await vad.processStreamingChunk(frame, state: vadState)
                guard token == generation, recording else { return }
                vadState = result.state; buffer.probability = result.probability
                maxProbability = max(maxProbability, result.probability)
                if result.probability >= 0.5 { speechWindows += 1 }
            } catch {
                guard token == generation else { return }
                fail(error); return
            }
            policy?.step(frame)
            drainFinals()
        }
        let interval = mode == .fast ? 16_000 : 28_800
        if buffer.open, buffer.audio.count >= 16_000, buffer.audio.count - buffer.lastRequestedSample >= interval {
            buffer.lastRequestedSample = buffer.audio.count
            draft = (buffer.epoch, buffer.audio)
        }
        startWorker(); emit()
    }
    private func drainFinals() {
        if !buffer.finalRequests.isEmpty {
            for (id, audio, fallback) in buffer.finalRequests { finals.append((id, audio)); confirmed[id] = fallback }
            buffer.finalRequests.removeAll()
            draft = nil
        }
    }
    private func startWorker() {
        guard worker == nil, !closed, !finals.isEmpty || draft != nil else { return }
        let token = generation
        worker = Task { await self.run(token) }
    }
    private func run(_ token: UUID) async {
        while token == generation, !Task.isCancelled {
            let finalID: UInt64?, epoch: Int, audio: [Float]
            if !finals.isEmpty {
                let next = finals.removeFirst(); finalID = next.0; audio = next.1; epoch = -1
            } else if let next = draft { finalID = nil; audio = next.samples; epoch = next.epoch; draft = nil }
            else { break }
            do {
                recognitionPasses += 1
                let result = try await lane.transcribe(audio, language: language).trimmingCharacters(in: .whitespacesAndNewlines)
                guard token == generation, !Task.isCancelled else { return }
                if let finalID {
                    confirmed[finalID] = result
                    policy?.applyCorrection(finalID, text: result)
                } else if buffer.epoch == epoch, buffer.open, recording { buffer.text = result }
                emit()
            } catch { guard token == generation, !Task.isCancelled else { return }; fail(error); break }
        }
        if token == generation { worker = nil }
    }
    private func emit() {
        guard let utterance else { return }
        let complete = confirmed.sorted { $0.key < $1.key }.map(\.value).filter { !$0.isEmpty }.joined(separator: " ")
        // Once an epoch closes, its partial draft must not be appended again.
        let currentDraft = recording && buffer.open ? buffer.text : ""
        let text = [complete, currentDraft].filter { !$0.isEmpty }.joined(separator: " ")
        guard text != lastText else { return }; lastText = text; textRevision &+= 1
        onText?(utterance, text); onSnapshot?(utterance, snapshot())
    }
    private func snapshot() -> CaptionSnapshot {
        let value = policy?.snapshot() ?? .init(revision: 0, confirmed: [], provisional: "")
        let boundary = value.confirmed.prefix { $0.state == .confirmed }.last?.endSample ?? 0
        return .init(revision: textRevision, confirmed: value.confirmed, provisional: recording && buffer.open ? buffer.text : "", settledThroughSample: boundary)
    }
    private func fail(_ error: Error) { failure = error.localizedDescription; recording = false; onError?(error.localizedDescription) }
    func finish() async throws -> BackgroundSpeechResult {
        guard !closed, utterance != nil else { throw CancellationError() }
        let token = generation
        recording = false
        // Preserve the true tail at Stop; pad VAD only, never discard captured speech.
        if !tail.isEmpty, let vad {
            let audio = tail
            let result = try await vad.processStreamingChunk(audio, state: vadState)
            guard token == generation else { throw CancellationError() }
            buffer.probability = result.probability; vadState = result.state
            policy?.step(audio); tail.removeAll()
        }
        policy?.finish(); draft = nil; drainFinals(); startWorker()
        while let worker { await worker.value; if token != generation { throw CancellationError() } }
        if let failure { throw NSError(domain: "MurMur.KeyboardSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]) }
        emit()
        return BackgroundSpeechResult(text: confirmed.sorted { $0.key < $1.key }.map(\.value).filter { !$0.isEmpty }.joined(separator: " "), seconds: Double(samples) / 16_000,
                                      speechWindows: speechWindows, maximumSpeechProbability: maxProbability, maximumInputLevel: maxInput, recognitionPasses: recognitionPasses, snapshot: snapshot())
    }
    func discard() {
        generation = UUID(); worker?.cancel(); worker = nil
        recording = false; utterance = nil; policy = nil; tail = []; confirmed = [:]; draft = nil; finals = []
        vadState = .initial()
    }
    func shutdown() async {
        closed = true
        let pending = worker; discard(); await pending?.value
        await lane.close(); vad = nil
    }
}
