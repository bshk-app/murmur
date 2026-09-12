import MurmurCore
import Foundation
import MLX
import MLXAudioSTT
import CoreML
import FluidAudio
import HuggingFace

public enum SpeechEvent: Sendable {
    case parallelProgress(liveFramesDuringCorrection: Int, maxLiveStepSeconds: Double)
    case draft(epoch: Int, text: String)
    case correctionStarted(id: UInt64, audioSeconds: Double)
    case correctionFinished(id: UInt64, text: String, seconds: Double)
    case correctionFailed(id: UInt64, message: String)
    case vad(probability: Float?, error: String?)
}

/// Core ML owns the complete corrector. It never submits MLX operations, so
/// the heavy encoder cannot hold up the GPU live lane's MLX scheduler.
private actor PhoneCorrector {
    private var manager: AsrManager?
    private var gigaam: GigaAMCorrector?
    private let choice: SpeechModelChoice
    private let ane: Bool
    private let quantization: String
    private var previous: Task<String, Error>?
    private var serialID: UInt64 = 0

    init(ane: Bool, quantization: String, choice: SpeechModelChoice) {
        self.ane = ane; self.quantization = quantization; self.choice = choice
    }

    func load(onProgress: @escaping @MainActor @Sendable (Progress) -> Void) async throws {
        if choice == .gigaam {
            if gigaam == nil { gigaam = try await GigaAMCorrector.load(ane: ane, onProgress: onProgress) }
            return
        }
        guard manager == nil else { return }
        let encoderName = quantization == "int4" ? "EncoderInt4.mlmodelc" : "Encoder.mlmodelc"
        let repo = HuggingFace.Repo.ID(rawValue: SpeechSession.coreMLRepo)!
        let cache = HubCache.default
        let root = cache.snapshotsDirectory(repo: repo, kind: .model)
            .appendingPathComponent(SpeechSession.coreMLRevision)
        let readiness = cache.cacheDirectory.appendingPathComponent("murmur-coreml-readiness")
        try FileManager.default.createDirectory(at: readiness, withIntermediateDirectories: true)
        let client = HubClient(cache: cache)
        let marker = readiness.appendingPathComponent("ready-\(encoderName)-\(SpeechSession.coreMLRevision)")
        if !FileManager.default.fileExists(atPath: marker.path) {
            // A recursive Hub listing includes directories. Broad package globs
            // select those too, turning analytics/ into a file download and
            // colliding with its children. Pass only exact regular-file paths.
            let entries = try await client.listFiles(in: repo, kind: .model,
                                                     revision: SpeechSession.coreMLRevision, recursive: true)
            let files = CoreMLSnapshotFiles.select(from: entries, encoder: encoderName)
            guard !files.isEmpty else {
                throw NSError(domain: "Murmur.ModelDownload", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No matching Core ML files in the pinned snapshot."])
            }
            // Use the SDK snapshot directly, without a second destination copy.
            _ = try await client.downloadSnapshot(of: repo, kind: .model, revision: SpeechSession.coreMLRevision,
                matching: files,
                progressHandler: onProgress)
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = ane ? .cpuAndNeuralEngine : .cpuOnly
            let cpu = MLModelConfiguration()
            cpu.computeUnits = .cpuOnly
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("parakeet_vocab.json")))
            let vocabulary: [Int: String]
            if let tokens = raw as? [String: String] {
                vocabulary = Dictionary(uniqueKeysWithValues: tokens.compactMap { key, value in Int(key).map { ($0, value) } })
            } else if let tokens = raw as? [String] {
                vocabulary = Dictionary(uniqueKeysWithValues: tokens.enumerated().map { ($0.offset, $0.element) })
            } else { throw CocoaError(.fileReadCorruptFile) }
            let models = AsrModels(
                encoder: try MLModel(contentsOf: root.appendingPathComponent(encoderName), configuration: configuration),
                preprocessor: try MLModel(contentsOf: root.appendingPathComponent("Preprocessor.mlmodelc"), configuration: cpu),
                decoder: try MLModel(contentsOf: root.appendingPathComponent("Decoder.mlmodelc"), configuration: cpu),
                joint: try MLModel(contentsOf: root.appendingPathComponent("JointDecision.mlmodelc"), configuration: cpu),
                configuration: configuration, vocabulary: vocabulary, version: .v3)
            manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1), models: models)
            _ = try await correct([Float](repeating: 0, count: 16_000))
            try Data("validated".utf8).write(to: marker, options: .atomic)
        } catch {
            manager = nil
            // If iOS evicted a cached file, the next attempt must resolve the
            // snapshot again instead of trusting the stale readiness marker.
            if FileManager.default.fileExists(atPath: marker.path) {
                try? FileManager.default.removeItem(at: marker)
            }
            throw error
        }
    }

    func unload() { manager = nil; gigaam = nil; previous = nil }

    func correct(_ samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        if let gigaam { return try gigaam.correct(samples) }
        guard let manager, !samples.isEmpty else { return "" }
        // VAD/Stop can close a sub-second phrase. FluidAudio requires at
        // least one second; right-pad instead of rejecting or dropping speech.
        let input = samples.count < 16_000
            ? samples + [Float](repeating: 0, count: 16_000 - samples.count)
            : samples
        let preceding = previous
        serialID &+= 1
        let id = serialID
        let task = Task {
            _ = try? await preceding?.value
            try Task.checkCancellation()
            var state = try TdtDecoderState()
            return try await manager.transcribe(input, decoderState: &state).text
        }
        previous = task
        defer { if serialID == id { previous = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

private final class PhoneLiveResources {
    let model: NemotronASRModel?
    let vad: SpeechBoundaryDetector
    var live: NemotronASRStreamSession?
    var vadFrames = 0
    var liveFrames = 0
    var corrections: [(UInt64, Range<Int>, [Float])] = []
    var correctionContext = CorrectionContext()
    var epoch = 0
    var lastDraft = ""
    init(model: NemotronASRModel?, vad: SpeechBoundaryDetector) { self.model = model; self.vad = vad }
}

private actor PhoneStreamingEngine {
    private let choice: SpeechModelChoice
    private let independent: Bool
    private let modelsRoot: URL
    private let ane: Bool
    private let independentCorrector = PhoneIndependentCorrector()
    private var usesGPUBatch: Bool { choice.usesGPU && !independent }
    private var gpuCorrector: PhoneMLXCorrector?
    private var language: String?
    private var nemotron: NemotronASRModel?
    private var vad: SpeechBoundaryDetector?
    private let corrector: PhoneCorrector
    private var policy: CaptionEngine?
    private var resources: PhoneLiveResources?
    private var jobs: [UInt64: Task<Void, Never>] = [:]
    private var pendingRanges: [UInt64: Range<Int>] = [:]
    private var generation = UUID()
    private var stopped = false
    private var completedWhileRecording = 0
    private var activeIndependentRequests: Set<UInt64> = []
    private var liveFramesDuringCorrection = 0
    private var maxLiveStepSeconds = 0.0
    private var onSnapshot: (@Sendable (CaptionSnapshot, Int, Int, Int) -> Void)?
    private var onError: (@Sendable (String) -> Void)?
    private var onModelEvent: (@Sendable (SpeechEvent) -> Void)?
    private var onQueueDepth: (@Sendable (Int) -> Void)?

    init(ane: Bool, quantization: String, choice: SpeechModelChoice, independent: Bool, modelsRoot: URL) {
        self.choice = choice
        self.independent = independent
        self.modelsRoot = modelsRoot
        self.ane = ane
        corrector = PhoneCorrector(ane: ane, quantization: quantization, choice: choice)
    }

    func load(_ mode: DictationMode, onPreparation: @escaping @MainActor @Sendable (String) -> Void,
              onProgress: @escaping @MainActor @Sendable (Progress) -> Void) async throws {
        guard !usesGPUBatch || mode != .hybrid else {
            throw NSError(domain: "Murmur.ASR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Для этой GPU-модели пока доступен точный режим. Независимый двойной backend ещё не подключён."])
        }
        if vad == nil {
            vad = try await Device.withDefaultDevice(.gpu) { try await SpeechBoundaryDetector.load() }
            let quiet = Device.withDefaultDevice(.gpu) {
                vad?.warmUp()
                let frame = [Float](repeating: 0, count: 512)
                let silent = (0..<32).allSatisfy { _ in vad?.isSpeech(frame) == false }
                vad?.reset()
                return silent
            }
            guard quiet else {
                throw NSError(domain: "Murmur.VAD", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Silero VAD не прошёл проверку тишины."])
            }
        }
        if mode != .accurate, nemotron == nil {
            try await SpeechAssets.prepareFastModel { progress, file in
                onProgress(progress)
                onPreparation("Загрузка Nemotron: \(file)")
            }
            nemotron = try await Device.withDefaultDevice(.gpu) {
                try await NemotronASRModel.fromPretrained(SpeechSession.nemotronRepository)
            }
            Device.withDefaultDevice(.gpu) {
                let warm = nemotron?.makeStreamSession(language: "ru", chunkMs: 160)
                _ = warm?.step([Float](repeating: 0, count: 16000))
                _ = warm?.finish()
            }
        }
        if mode != .fast {
            if independent {
                try await independentCorrector.load(choice: choice, ane: ane, modelsRoot: modelsRoot, onPreparation: onPreparation)
            } else if usesGPUBatch {
                if gpuCorrector == nil { gpuCorrector = try await PhoneMLXCorrector.load(choice, modelsRoot: modelsRoot, onProgress: onProgress) }
            } else { try await corrector.load(onProgress: onProgress) }
        }
    }

    /// Executes a short synthetic input without opening the microphone or emitting captions.
    func warmUp(mode: DictationMode, language: String?) async throws {
        try Task.checkCancellation()
        guard mode != .fast else { return } // Live ASR and VAD warm during load.
        let silence = [Float](repeating: 0, count: 16_000)
        if independent { _ = try await independentCorrector.correct(silence, language: language) }
        else if let gpuCorrector { _ = try gpuCorrector.correct(silence, language: language) }
        else { _ = try await corrector.correct(silence) }
        try Task.checkCancellation()
    }

    func begin(mode: DictationMode, language: String?, onError: @escaping @Sendable (String) -> Void,
               onModelEvent: @escaping @Sendable (SpeechEvent) -> Void,
               onQueueDepth: (@Sendable (Int) -> Void)? = nil,
               onSnapshot: @escaping @Sendable (CaptionSnapshot, Int, Int, Int) -> Void) {
        for job in jobs.values { job.cancel() }
        jobs.removeAll()
        pendingRanges.removeAll()
        generation = UUID()
        stopped = false
        completedWhileRecording = 0
        activeIndependentRequests.removeAll()
        liveFramesDuringCorrection = 0
        maxLiveStepSeconds = 0
        self.onSnapshot = onSnapshot
        self.onError = onError
        self.onModelEvent = onModelEvent
        self.onQueueDepth = onQueueDepth
        self.language = language
        guard let vad else { return }
        Device.withDefaultDevice(.gpu) { vad.reset() }
        let lane = PhoneLiveResources(model: mode == .accurate ? nil : nemotron, vad: vad)
        resources = lane
        policy = CaptionEngine(
            live: .init(
                begin: {
                    lane.epoch += 1
                    lane.lastDraft = ""
                    lane.live = lane.model?.makeStreamSession(language: language, chunkMs: 160)
                },
                step: { samples in
                    guard let live = lane.live else { return }
                    lane.liveFrames += 1
                    _ = live.step(samples)
                },
                text: { lane.live?.text ?? "" },
                finish: { _ = lane.live?.finish() }
            ),
            isSpeech: { frame in
                lane.vadFrames += 1
                return Device.withDefaultDevice(.gpu) { lane.vad.isSpeech(frame) }
            },
            batch: { _, _ in "" },
            maxEpochSeconds: usesGPUBatch ? 28 : 4,
            enqueueCorrection: { id, range, audio in lane.corrections.append((id, range, audio)) }
        )
        currentMode = mode
    }

    private var currentMode = DictationMode.hybrid

    private func submitCorrections() {
        guard let resources else { return }
        let queued = resources.corrections
        resources.corrections.removeAll()
        for (id, range, samples) in queued {
            let request = resources.correctionContext.append(id: id, range: range, audio: samples)
            enqueue(id: id, samples: request.samples, range: request.range, replacing: request.segmentIDs, token: generation, mode: currentMode)
        }
    }

    private func enqueue(id: UInt64, samples: [Float], range: Range<Int>, replacing ids: [UInt64], token: UUID, mode: DictationMode) {
        guard token == generation else { return }
        if mode == .fast { policy?.applyCorrection(id, text: ""); emit(); return }
        pendingRanges[id] = range
        onModelEvent?(.correctionStarted(id: id, audioSeconds: Double(samples.count) / 16000))
        let worker = corrector
        let independentWorker = independentCorrector
        let useIndependent = independent
        let contextLanguage = language
        jobs[id] = Task { [weak self] in
            let started = Date()
            let result: String
            do {
                if useIndependent {
                    result = try await independentWorker.correct(samples, language: contextLanguage) { [weak self] in
                        await self?.markIndependentStarted(id: id, token: token)
                    }
                } else if let self, await self.usesGPUBatch { result = try await self.correctOnGPU(samples) }
                else { result = try await worker.correct(samples) }
            }
            catch {
                guard !Task.isCancelled else { return }
                await self?.failCorrection(id: id, message: String(describing: error), token: token)
                return
            }
            guard !Task.isCancelled else { return }
            await self?.accept(id: id, text: result, replacing: ids, seconds: Date().timeIntervalSince(started), token: token)
        }
    }

    private func failCorrection(id: UInt64, message: String, token: UUID) {
        guard generation == token else { return }
        activeIndependentRequests.remove(id)
        jobs[id] = nil
        pendingRanges[id] = nil
        onModelEvent?(.correctionFailed(id: id, message: message))
        onError?("Корректор: \(message)")
        policy?.applyCorrection(id, text: "")
        emit()
    }

    private func markIndependentStarted(id: UInt64, token: UUID) {
        guard generation == token else { return }
        activeIndependentRequests.insert(id)
    }

    private func correctOnGPU(_ samples: [Float]) throws -> String {
        guard let gpuCorrector else { throw CocoaError(.featureUnsupported) }
        return try gpuCorrector.correct(samples, language: language)
    }

    private func accept(id: UInt64, text: String, replacing ids: [UInt64], seconds: Double, token: UUID) {
        guard token == generation else { return }
        activeIndependentRequests.remove(id)
        jobs[id] = nil
        pendingRanges[id] = nil
        onModelEvent?(.correctionFinished(id: id, text: text, seconds: seconds))
        policy?.applyCorrection(id, text: text, replacing: ids)
        if !stopped, !text.isEmpty { completedWhileRecording += 1 }
        emit()
    }

    func step(_ samples: [Float]) {
        guard !Task.isCancelled else { return }
        let before = resources?.liveFrames ?? 0
        let start = ProcessInfo.processInfo.systemUptime
        Device.withDefaultDevice(.gpu) { policy?.step(samples) }
        maxLiveStepSeconds = max(maxLiveStepSeconds, ProcessInfo.processInfo.systemUptime - start)
        if !activeIndependentRequests.isEmpty {
            liveFramesDuringCorrection += (resources?.liveFrames ?? 0) - before
        }
        submitCorrections()
        emit()
    }

    private func emit() {
        onQueueDepth?(jobs.count)
        guard let policy, let resources else { return }
        onModelEvent?(.parallelProgress(liveFramesDuringCorrection: liveFramesDuringCorrection, maxLiveStepSeconds: maxLiveStepSeconds))
        if let draft = resources.live?.text, !draft.isEmpty, draft != resources.lastDraft {
            resources.lastDraft = draft
            onModelEvent?(.draft(epoch: resources.epoch, text: draft))
        }
        onModelEvent?(.vad(probability: resources.vad.lastProbability, error: resources.vad.lastError))
        onSnapshot?(currentSnapshot(), resources.vadFrames, resources.liveFrames, completedWhileRecording)
    }

    func currentSnapshot() -> CaptionSnapshot {
        guard let policy else { return .init(revision: 0, confirmed: [], provisional: "") }
        let snapshot = policy.snapshot()
        let end = snapshot.confirmed.last?.endSample ?? 0
        let contextStart = (!policy.isUtteranceOpen || currentMode == .fast) ? end : (resources?.correctionContext.startSample ?? 0)
        let boundary = min(contextStart, pendingRanges.values.map(\.lowerBound).min() ?? contextStart)
        return .init(revision: snapshot.revision, confirmed: snapshot.confirmed, provisional: snapshot.provisional, settledThroughSample: boundary)
    }

    func finish() async -> String {
        stopped = true
        Device.withDefaultDevice(.gpu) { policy?.finish() }
        submitCorrections()
        while !jobs.isEmpty {
            let pending = Array(jobs.values)
            for job in pending { await job.value }
        }
        emit()
        let snapshot = policy?.snapshot()
        return snapshot?.confirmed.map(\.text).joined(separator: " ") ?? ""
    }

    func shutdown() async {
        let pending = Array(jobs.values)
        cancel()
        for job in pending { await job.value }
        await independentCorrector.unload()
        await corrector.unload()
        gpuCorrector = nil; nemotron = nil; vad = nil; resources = nil
        // The allocator otherwise keeps unused GPU buffers for a later session.
        Memory.clearCache()
    }

    func cancel() {
        generation = UUID()
        for job in jobs.values { job.cancel() }
        jobs.removeAll()
        pendingRanges.removeAll()
        policy = nil
    }
}

/// Owns mic lifecycle. AsyncStream preserves capture order; inference runs off
/// the capture callback. The engine actor and CPU corrector progress independently.
public final class SpeechSession: @unchecked Sendable {
    public static let nemotronRepository = "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
    public static let coreMLRepo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    public static let coreMLRevision = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
    public var onSnapshot: (@Sendable (CaptionSnapshot, Int, Int, Int) -> Void)?
    public var onError: (@Sendable (String) -> Void)?
    public var onModelEvent: (@Sendable (SpeechEvent) -> Void)?
    public var onQualificationTelemetry: (@Sendable (SpeechQualificationSnapshot) -> Void)?
    public private(set) var recognitionProfile: SpeechRecognitionProfile?
    private let qualificationTelemetry = SpeechQualificationTelemetry()
    public var onCapture: ((Int, Double, Float, String?) -> Void)?
    public var onRecordingError: (@Sendable (String) -> Void)?
    private let recording = RecordingAudioSink()
    private let engine: PhoneStreamingEngine
    private var mic = MicCapture()
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var consumer: Task<Void, Never>?
    public private(set) var capturedSeconds = 0.0
    public private(set) var capturedPeak: Float = 0

    public init(quantization: String, ane: Bool, memoryLimit: Int, corrector: SpeechModelChoice = .parakeet, independent: Bool = false, modelsRoot: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        GPU.set(memoryLimit: memoryLimit, relaxed: false)
        engine = PhoneStreamingEngine(ane: ane, quantization: quantization, choice: corrector, independent: independent, modelsRoot: modelsRoot)
    }

    public convenience init(profile: SpeechRecognitionProfile, quantization: String = "int4", ane: Bool = true,
                            memoryLimit: Int, modelsRoot: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.init(quantization: quantization, ane: ane, memoryLimit: memoryLimit, corrector: profile.model,
                  independent: profile.independentCorrector, modelsRoot: modelsRoot)
        recognitionProfile = profile
    }

    public func qualificationSnapshot() -> SpeechQualificationSnapshot { qualificationTelemetry.snapshot() }
    private func publishQualificationTelemetry() {
        guard let callback = onQualificationTelemetry else { return }
        callback(qualificationTelemetry.snapshot())
    }

    public func load(mode: DictationMode, onPreparation: @escaping @MainActor @Sendable (String) -> Void = { _ in }, onProgress: @escaping @MainActor @Sendable (Progress) -> Void = { _ in }) async throws {
        try await engine.load(mode, onPreparation: onPreparation, onProgress: onProgress)
    }
    public func requestMicrophonePermission(_ callback: @escaping (Bool) -> Void) { MicCapture.requestPermission(callback) }
    public static func requestMicrophoneAccess(_ callback: @escaping (Bool) -> Void) { MicCapture.requestPermission(callback) }

    public func warmUp(mode: DictationMode, language: String?) async throws {
        try await engine.warmUp(mode: recognitionProfile?.mode ?? mode, language: recognitionProfile?.language ?? language)
    }

    public func start(mode: DictationMode, language: String?, microphoneUID: String?, recordingURL: URL? = nil) async throws {
        let mode = recognitionProfile?.mode ?? mode
        let language = recognitionProfile?.language ?? language
        qualificationTelemetry.reset()
        try recording.begin(url: recordingURL)
        await engine.begin(mode: mode, language: language,
                           onError: { [weak self] in self?.onError?($0) },
                           onModelEvent: { [weak self] event in
                               if case .draft = event { self?.qualificationTelemetry.observedPreview() }
                               if case .correctionFailed = event { self?.qualificationTelemetry.correctionFailed() }
                               self?.onModelEvent?(event)
                           }, onQueueDepth: { [weak self] depth in
                               self?.qualificationTelemetry.pendingCorrections(depth)
                               self?.publishQualificationTelemetry()
                           }) { [weak self] in self?.onSnapshot?($0, $1, $2, $3) }
        let stream = AsyncStream<[Float]> { continuation = $0 }
        consumer = Task { [engine, qualificationTelemetry] in
            for await chunk in stream {
                if Task.isCancelled { break }
                await engine.step(chunk)
                qualificationTelemetry.audioQueued(-1)
            }
        }
        mic = MicCapture(inputDeviceUID: microphoneUID)
        mic.onCapture = { [weak self] frames, rate, peak, error in
            self?.onCapture?(frames, rate, peak, error)
            if let error { self?.onRecordingError?(error) }
        }
        mic.onChunk = { [weak self] samples in
            guard let self else { return }
            do { try self.recording.append(samples) }
            catch { self.onRecordingError?(error.localizedDescription) }
            self.qualificationTelemetry.audioQueued(1)
            self.continuation?.yield(samples)
        }
        do { try mic.start() }
        catch { continuation?.finish(); consumer?.cancel(); throw error }
    }

    public func stop() async -> String {
        let finalStart = ProcessInfo.processInfo.systemUptime
        let result = mic.stop()
        do { try recording.finish() } catch { onRecordingError?(error.localizedDescription) }
        capturedSeconds = result.durationS
        capturedPeak = result.peakRMS
        continuation?.finish()
        await consumer?.value
        let text = await engine.finish()
        qualificationTelemetry.finished(since: finalStart)
        publishQualificationTelemetry()
        return text
    }

    public func cancel() {
        _ = mic.stop()
        try? recording.finish()
        continuation?.finish()
        consumer?.cancel()
        Task { await engine.cancel() }
    }

    public func close() async {
        _ = mic.stop()
        do { try recording.finish() } catch { onRecordingError?(error.localizedDescription) }
        continuation?.finish(); consumer?.cancel()
        await consumer?.value
        await engine.shutdown()
    }

    public func snapshot() async -> CaptionSnapshot { await engine.currentSnapshot() }

    /// Qualification-only fixed-rate source. Producer deadlines never wait for
    /// inference: overload becomes observable audio backlog. This is not a mic.
    /// Do not run concurrently with capture/replay on the same session.
    public func replayRealtimeForQualification(_ samples: [Float], mode: DictationMode,
                                              language: String?) async throws -> SpeechReplayResult {
        let mode = recognitionProfile?.mode ?? mode
        let language = recognitionProfile?.language ?? language
        qualificationTelemetry.reset()
        await engine.begin(mode: mode, language: language,
            onError: { [weak self] in self?.onError?($0) },
            onModelEvent: { [weak self] event in
                if case .draft = event { self?.qualificationTelemetry.observedPreview() }
                if case .correctionFailed = event { self?.qualificationTelemetry.correctionFailed() }
                self?.onModelEvent?(event)
            }, onQueueDepth: { [weak self] depth in
                self?.qualificationTelemetry.pendingCorrections(depth)
                self?.publishQualificationTelemetry()
            }) { [weak self] in self?.onSnapshot?($0, $1, $2, $3) }
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        let start = ProcessInfo.processInfo.systemUptime
        let telemetry = qualificationTelemetry
        let producer = Task.detached(priority: .userInitiated) { () throws -> Double in
            defer { continuation.finish() }
            for offset in stride(from: 0, to: samples.count, by: 1536) {
                try Task.checkCancellation()
                let end = min(offset + 1536, samples.count)
                let deadline = start + Double(end) / 16_000
                let delay = deadline - ProcessInfo.processInfo.systemUptime
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                try Task.checkCancellation()
                telemetry.inputScheduleLag(max(0, ProcessInfo.processInfo.systemUptime - deadline))
                telemetry.audioQueued(1)
                continuation.yield(Array(samples[offset..<end]))
            }
            return ProcessInfo.processInfo.systemUptime
        }
        do {
            return try await withTaskCancellationHandler {
                var compute = 0.0
                for await chunk in stream {
                    try Task.checkCancellation()
                    let tick = ProcessInfo.processInfo.systemUptime
                    await engine.step(chunk)
                    compute += ProcessInfo.processInfo.systemUptime - tick
                    telemetry.audioQueued(-1)
                }
                let inputEnded = try await producer.value
                try Task.checkCancellation()
                let finalTick = ProcessInfo.processInfo.systemUptime
                let text = await engine.finish()
                compute += ProcessInfo.processInfo.systemUptime - finalTick
                try Task.checkCancellation()
                telemetry.finished(since: inputEnded)
                publishQualificationTelemetry()
                return SpeechReplayResult(text: text, audioSeconds: Double(samples.count) / 16_000,
                    computeSeconds: compute, wallSeconds: ProcessInfo.processInfo.systemUptime - start)
            } onCancel: {
                producer.cancel()
                continuation.finish()
                Task { await self.engine.cancel() }
            }
        } catch {
            producer.cancel(); continuation.finish()
            _ = try? await producer.value
            await engine.cancel()
            throw error
        }
    }

    public func transcribeOffline(_ samples: [Float], mode: DictationMode, language: String?, onAudio: ([Float]) -> Void = { _ in }) async -> SpeechReplayResult {
        let mode = recognitionProfile?.mode ?? mode
        let language = recognitionProfile?.language ?? language
        qualificationTelemetry.reset()
        await engine.begin(mode: mode, language: language,
                           onError: { [weak self] in self?.onError?($0) },
                           onModelEvent: { [weak self] event in
                               if case .draft = event { self?.qualificationTelemetry.observedPreview() }
                               if case .correctionFailed = event { self?.qualificationTelemetry.correctionFailed() }
                               self?.onModelEvent?(event)
                           }, onQueueDepth: { [weak self] depth in
                               self?.qualificationTelemetry.pendingCorrections(depth)
                               self?.publishQualificationTelemetry()
                           }) { [weak self] in self?.onSnapshot?($0, $1, $2, $3) }
        let start = Date()
        var compute = 0.0
        for offset in stride(from: 0, to: samples.count, by: 1536) {
            let tick = Date()
            let chunk = Array(samples[offset..<min(offset + 1536, samples.count)])
            onAudio(chunk)
            await engine.step(chunk)
            let elapsed = Date().timeIntervalSince(tick)
            compute += elapsed
            // Replay at microphone pace so corrections can be observed before Stop.
            if elapsed < 0.096 { try? await Task.sleep(for: .seconds(0.096 - elapsed)) }
        }
        let finalStart = Date()
        let monotonicFinalStart = ProcessInfo.processInfo.systemUptime
        let text = await engine.finish()
        qualificationTelemetry.finished(since: monotonicFinalStart)
        publishQualificationTelemetry()
        compute += Date().timeIntervalSince(finalStart)
        return SpeechReplayResult(text: text, audioSeconds: Double(samples.count) / 16000,
                             computeSeconds: compute, wallSeconds: Date().timeIntervalSince(start))
    }
}

/// A single recognizer with no MLX/GPU work. Suitable for evaluating background audio sessions.
public actor CoreMLSpeechLane {
    private let choice: SpeechModelChoice
    private let ane: Bool
    private let root: URL
    private let standard: PhoneCorrector
    private let independentWorker = PhoneIndependentCorrector()
    public init(choice: SpeechModelChoice, ane: Bool = true, modelsRoot: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.choice = choice; self.ane = ane; root = modelsRoot
        standard = PhoneCorrector(ane: ane, quantization: "int4", choice: choice)
    }
    public func load() async throws {
        if choice.usesGPU { try await independentWorker.load(choice: choice, ane: ane, modelsRoot: root) }
        else { try await standard.load(onProgress: { _ in }) }
    }
    public func transcribe(_ samples: [Float], language: String?) async throws -> String {
        if choice.usesGPU { return try await independentWorker.correct(samples, language: language) }
        return try await standard.correct(samples)
    }
    public func close() async { await standard.unload(); await independentWorker.unload() }
}

/// Silero VAD explicitly on CPU: it does not depend on the GPU live lane.
public actor CoreMLVoiceActivity {
    private let detector: VadManager
    public init() async throws { detector = try await VadManager(config: VadConfig(computeUnits: .cpuOnly)) }
    public func probabilities(_ samples: [Float]) async throws -> [Float] {
        try await detector.process(samples).map(\.probability)
    }
}
