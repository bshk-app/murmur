#if DEBUG
import SwiftUI
import AVFoundation
import CryptoKit
import Darwin
import MurmurCore
import MurmurSpeech
import MurmurTranslation

/// Explicit diagnostic launch only. Results are raw exploratory observations,
/// never a qualification decision and never an instruction to promote a model.
struct QualityQualificationProbe: View {
    @State private var status = "Reading qualification request"
    @State private var started = false
    var body: some View {
        Text(status).padding().task {
            guard !started else { return }; started = true
            let runner = QualityProbeRunner()
            if ProcessInfo.processInfo.arguments.contains("--prepare-qualification-preview") {
                await runner.preparePreview { status = $0 }
            } else {
                await runner.run { status = $0 }
            }
        }
        // Keep the diagnostic screen awake between runs while fixtures/results
        // are transferred. Restore normal idle behavior when leaving this view.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

private struct QualityProbeRequest: Decodable {
    struct Sample: Decodable {
        let id: String
        let source: String
        let target: String
        let scenario: String
        let text: String?
        let fixturePath: String?
        let speechRuntimeID: String?
        let speechMode: String?
        let speechPipeline: String?
        let speechModelsDirectory: String?
        let translationModelsRoot: String?
        let translationBindings: [TranslationModelBinding]?
    }
    let schemaVersion: Int
    let runID: String
    let repetitions: Int?
    let stressDurationSeconds: Double?
    let allowASRPreparation: Bool?
    let samples: [Sample]
}

/// No downloading, no quality fallback. Page processing consumes the same strict
/// OPUS service, while preserving the production PageTranslationProcessor flow.
private actor QualityProbeTextEngine: TextTranslationEngine {
    let service: TranslationService
    private var passes: [TranslationService.Pass] = []
    init(service: TranslationService) { self.service = service }
    func prepare(from: String, to: String, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        guard let profile = service.qualityProfile(from: from, to: to),
              profile.models.allSatisfy({ service.hasQualityModel(for: $0) }) else {
            throw TranslationService.QualityUnavailable(pair: .init(source: from, target: to))
        }
        await onProgress(1)
    }
    func translate(_ text: String, from: String, to: String) async throws -> String {
        let output = try await service.translateQuality(text, from: from, to: to)
        passes += output.passes
        guard output.usedQuality else { throw CocoaError(.validationMissingMandatoryProperty) }
        return output.text
    }
    var residentModelCount: Int { get async { await service.residentModelCount } }
    func unload() async { await service.evictAll() }
    func recordedPasses() -> [TranslationService.Pass] { passes }
}

private final class QualityProbeMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    private var warnings = 0
    private var peak: UInt64 = 0
    private var lastSpeech: SpeechQualificationSnapshot?
    private let log: FileHandle
    private var samples = 0
    private var translationUpdates = 0
    private var translationFailures = 0
    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        log = try FileHandle(forWritingTo: url)
    }
    func translationUpdate() { lock.lock(); translationUpdates += 1; lock.unlock() }
    func translationFailure() { lock.lock(); translationFailures += 1; lock.unlock() }
    func warning() { lock.lock(); warnings += 1; lock.unlock() }
    func speech(_ value: SpeechQualificationSnapshot) { lock.lock(); lastSpeech = value; lock.unlock() }
    func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        lock.lock(); defer { lock.unlock() }
        if result == KERN_SUCCESS { peak = max(peak, info.phys_footprint) }
        var row: [String: Any] = ["uptime_s": ProcessInfo.processInfo.systemUptime,
            "memory_warnings": warnings, "thermal_state": ProcessInfo.processInfo.thermalState.rawValue]
        if result == KERN_SUCCESS { row["process_footprint_bytes"] = info.phys_footprint }
        if let lastSpeech, let data = try? JSONEncoder().encode(lastSpeech),
           let encoded = try? JSONSerialization.jsonObject(with: data) { row["speech"] = encoded }
        if var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            data.append(10); try? log.write(contentsOf: data)
        }
        samples += 1
        if samples % 10 == 0 { try? log.synchronize() }
    }
    func summary() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["memory_warnings": warnings, "sampled_peak_process_footprint_bytes": peak,
                "footprint_samples": samples, "translation_updates": translationUpdates, "translation_failures": translationFailures, "sampling_interval_requested_s": 0.1]
    }
    func close() { lock.lock(); defer { lock.unlock() }; try? log.synchronize(); try? log.close() }
}

/// Retains the actual finalized source ranges for segmentation experiments.
private actor QualityProbeSourceArchive {
    private var transcript = RecordingTranscript()
    func apply(_ snapshot: CaptionSnapshot) { transcript.apply(snapshot) }
    func finish(_ snapshot: CaptionSnapshot, fallback: String, endSample: Int) -> [RecordedUtterance] {
        transcript.apply(snapshot)
        transcript.finish(fallback: fallback, endSample: endSample)
        return transcript.utterances
    }
}

/// Serial delivery preserves caption revisions and production utterance assembly.
private actor QualityProbeConcurrentTranslation {
    private let session: TranslationSession
    private let source: String
    private let target: String
    private let measurements: QualityProbeMeasurements
    private var transcript = RecordingTranscript()
    private let profileCatalog: TranslationProfileCatalog
    private let qualityModelsRoots: [URL]
    init(source: String, target: String, measurements: QualityProbeMeasurements,
         profileCatalog: TranslationProfileCatalog = .baseline, qualityModelsRoots: [URL] = []) {
        self.source = source; self.target = target; self.measurements = measurements
        self.profileCatalog = profileCatalog; self.qualityModelsRoots = qualityModelsRoots
        session = TranslationSession(modelsRoot: StoragePaths.translation, qualityModelsRoots: qualityModelsRoots, profileCatalog: profileCatalog)
    }
    func prepare() async throws {
        let catalog = TranslationService(modelsRoot: StoragePaths.translation, qualityModelsRoots: qualityModelsRoots, profileCatalog: profileCatalog)
        guard let quality = catalog.qualityProfile(from: source, to: target),
              quality.models.allSatisfy({ catalog.hasQualityModel(for: $0) }) else {
            throw TranslationService.QualityUnavailable(pair: .init(source: source, target: target))
        }
        if let fast = catalog.route(from: source, to: target) {
            let legs: [LanguagePair]
            switch fast { case .direct(let pair): legs = [pair]; case .pivot(let a, let b): legs = [a, b] }
            guard legs.allSatisfy({ TranslationDownloader.isInstalled(pair: $0, in: StoragePaths.translation, kind: .fast) }) else {
                throw CocoaError(.fileNoSuchFile)
            }
        }
        // Every required package was checked above; do not acquire absent packs.
        try await session.prepare(from: source, to: target)
    }
    func warmUp() async throws { try await session.warmUp(from: source, to: target) }
    func update(_ snapshot: CaptionSnapshot) async {
        transcript.apply(snapshot)
        let measured = measurements
        await session.update(snapshot, from: source, to: target,
            onUpdate: { _ in measured.translationUpdate() }, onFailure: { _ in measured.translationFailure() })
    }
    func finish(_ snapshot: CaptionSnapshot, fallback: String, endSample: Int) async throws -> String {
        transcript.apply(snapshot)
        transcript.finish(fallback: fallback, endSample: endSample)
        try await session.finishUtterances(transcript.utterances, from: source, to: target) { [weak self] value in
            await self?.accept(value)
        }
        return transcript.translatedText
    }
    private func accept(_ value: UtteranceTranslation) { transcript.applyTranslations([value]) }
    func close() async { await session.unload() }
}

@MainActor private final class QualityProbeRunner {
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    /// Explicit setup command, separate from measured execution. The regular
    /// runner still refuses missing packages instead of downloading during a run.
    func preparePreview(status: (String) -> Void) async {
        var report: [String: Any] = ["schema_version": 1, "evidence_kind": "model_preparation_only", "status": "started"]
        let output = documents.appendingPathComponent("quality-preview-preparation-status.json")
        do {
            let bytes = try Data(contentsOf: documents.appendingPathComponent("quality-qualification-request.json"))
            let request = try JSONDecoder().decode(QualityProbeRequest.self, from: bytes)
            guard request.schemaVersion == 1, !request.samples.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            report["request_sha256"] = hash(bytes)
            try write(report, to: output)
            let catalog = TranslationService(modelsRoot: StoragePaths.translation)
            var seen = Set<LanguagePair>()
            var prepared: [String] = []
            for sample in request.samples {
                guard let route = catalog.route(from: sample.source, to: sample.target) else { continue }
                let legs: [LanguagePair]
                switch route { case .direct(let pair): legs = [pair]; case .pivot(let a, let b): legs = [a, b] }
                for pair in legs where seen.insert(pair).inserted {
                    status("Preparing preview package \(pair)")
                    try await TranslationDownloader.download(pair: pair, into: StoragePaths.translation, kind: .fast)
                    prepared.append(pair.description)
                    report["prepared_pairs"] = prepared
                    try write(report, to: output)
                }
            }
            report["status"] = "complete"
            status("Preview packages prepared; no benchmark was run")
        } catch {
            report["status"] = "failed"; report["error"] = String(describing: error)
            status("Preview preparation failed: \(error.localizedDescription)")
        }
        try? write(report, to: output)
    }
    private func write(_ value: [String: Any], to url: URL) throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: url, options: .atomic)
    }
    private func fixture(_ relative: String) throws -> URL {
        let root = documents.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard !relative.hasPrefix("/"), file.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadNoPermission) }
        return file
    }
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func audio(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              file.length > 0, file.length <= 16_000 * 3_600,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
    func run(status: (String) -> Void) async {
        let statusURL = documents.appendingPathComponent("quality-qualification-status.json")
        do {
            let requestBytes = try Data(contentsOf: documents.appendingPathComponent("quality-qualification-request.json"))
            let request = try JSONDecoder().decode(QualityProbeRequest.self, from: requestBytes)
            let repeats = request.repetitions ?? 3
            let stress = request.stressDurationSeconds ?? 0
            guard request.schemaVersion == 1, !request.runID.isEmpty,
                  request.runID.count <= 100, request.runID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  (1...100).contains(repeats), !request.samples.isEmpty,
                  Set(request.samples.map(\.id)).count == request.samples.count,
                  stress == 0 || (stress.isFinite && (1800...7200).contains(stress)) else { throw CocoaError(.fileReadCorruptFile) }
            let directory = documents.appendingPathComponent("quality-qualification/" + request.runID)
            // Never overwrite an earlier study. A fresh runID is required.
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try requestBytes.write(to: directory.appendingPathComponent("request.json"), options: .atomic)
            var manifest: [String: Any] = ["schema_version": 1, "evidence_kind": "exploratory_device_observations",
                "qualification_status": "not_qualified", "run_id": request.runID, "request_sha256": hash(requestBytes),
                "device": SpeechRecognitionProfile.currentDeviceIdentifier, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "repetitions_requested": repeats, "stress_duration_requested_s": stress, "completed_attempts": 0,
                "stress_contract": "repeated workloads unless one long speech fixture is supplied; inspect each speech_pipeline and actual audio_seconds",
                "run_status": "running", "output_directory": "quality-qualification/" + request.runID]
            #if targetEnvironment(simulator)
            manifest["simulator"] = true
            #else
            manifest["simulator"] = false
            #endif
            if let sourceURL = Bundle.main.url(forResource: "QualityQualificationBuild", withExtension: "json") {
                let sourceBytes = try Data(contentsOf: sourceURL)
                try sourceBytes.write(to: directory.appendingPathComponent("build-source.json"), options: .atomic)
                let source = try JSONSerialization.jsonObject(with: sourceBytes) as? [String: Any]
                manifest["source_sha256"] = source?["source_sha256"] ?? "unavailable"
            } else { manifest["source_sha256"] = "unavailable" }
            try write(manifest, to: directory.appendingPathComponent("manifest.json"))
            try write(manifest, to: statusURL)
            let started = ProcessInfo.processInfo.systemUptime
            var attempt = 0, cycle = 0
            repeat {
                for sample in request.samples {
                    for repetition in 0..<repeats {
                        try Task.checkCancellation()
                        status("\(sample.source) → \(sample.target) · \(sample.id) · \(repetition + 1)")
                        try await execute(sample, request: request, repetition: repetition, cycle: cycle,
                                      attempt: attempt, directory: directory)
                        attempt += 1
                        manifest["completed_attempts"] = attempt
                        manifest["elapsed_s"] = ProcessInfo.processInfo.systemUptime - started
                        try write(manifest, to: directory.appendingPathComponent("manifest.json"))
                        try write(manifest, to: statusURL)
                    }
                }
                cycle += 1
            } while stress > 0 && ProcessInfo.processInfo.systemUptime - started < stress
            manifest["run_status"] = "complete"
            manifest["elapsed_s"] = ProcessInfo.processInfo.systemUptime - started
            try write(manifest, to: directory.appendingPathComponent("manifest.json"))
            try write(manifest, to: statusURL)
            status("Saved \(attempt) exploratory attempts. Qualification is still required.")
        } catch {
            let failure: [String: Any] = ["run_status": "failed", "qualification_status": "not_qualified", "error": String(describing: error)]
            try? write(failure, to: statusURL)
            status(String(describing: error))
        }
    }
    private func execute(_ sample: QualityProbeRequest.Sample, request: QualityProbeRequest,
                         repetition: Int, cycle: Int, attempt: Int, directory: URL) async throws {
        let rowURL = directory.appendingPathComponent(String(format: "attempt-%06d.json", attempt))
        var row: [String: Any] = ["sample_id": sample.id, "source": sample.source, "target": sample.target,
            "scenario": sample.scenario, "repeat_id": repetition, "stress_cycle": cycle, "status": "started",
            "evidence_kind": "exploratory_device_observations", "device": SpeechRecognitionProfile.currentDeviceIdentifier]
        var session: SpeechSession?
        var concurrent: QualityProbeConcurrentTranslation?
        var engine: QualityProbeTextEngine?
        var measurements: QualityProbeMeasurements?
        var sampler: Task<Void, Never>?
        var observer: NSObjectProtocol?
        do {
            try write(row, to: rowURL)
            let measured = try QualityProbeMeasurements(url: directory.appendingPathComponent(String(format: "attempt-%06d-telemetry.jsonl", attempt)))
            measurements = measured
            observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in measured.warning() }
            sampler = Task.detached {
                while !Task.isCancelled { measured.sample(); try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard LanguagePair.qualityLanguages.contains(sample.source), LanguagePair.qualityLanguages.contains(sample.target),
                  sample.source != sample.target, let scenario = TranslationScenario(rawValue: sample.scenario == "pages" ? "page" : sample.scenario) else { throw CocoaError(.fileReadCorruptFile) }
            var catalog = TranslationProfileCatalog.baseline
            var extraRoots: [URL] = []
            if sample.translationModelsRoot != nil || sample.translationBindings != nil {
                guard let bindings = sample.translationBindings, !bindings.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                catalog = try TranslationProfileCatalog(version: "candidate-unqualified", bindings: bindings)
                for binding in bindings {
                    let directory: URL
                    if let relative = sample.translationModelsRoot {
                        directory = try fixture(relative + "/" + binding.directoryName)
                    } else {
                        // A decode-only experiment may reuse registered installed
                        // assets, but cannot change the language/tag contract.
                        guard let baseline = TranslationProfileCatalog.baseline.bindings[binding.pair],
                              baseline.modelID == binding.modelID,
                              baseline.directoryName == binding.directoryName,
                              baseline.targetTag == binding.targetTag else { throw CocoaError(.fileReadCorruptFile) }
                        directory = StoragePaths.translation.appendingPathComponent(binding.directoryName)
                    }
                    let actual = try TranslationModelIdentity.compute(directory: directory)
                    guard actual == binding.modelID else { throw CocoaError(.fileReadCorruptFile) }
                }
                if let relative = sample.translationModelsRoot { extraRoots = [try fixture(relative)] }
                row["translation_candidate_status"] = "explicit_unqualified_diagnostic_only"
                row["translation_models_root"] = sample.translationModelsRoot ?? "registered_baseline_storage"
            }
            let service = TranslationService(modelsRoot: StoragePaths.translation, qualityModelsRoots: extraRoots, profileCatalog: catalog, scenario: scenario)
            let textEngine = QualityProbeTextEngine(service: service); engine = textEngine
            try await textEngine.prepare(from: sample.source, to: sample.target) { _ in }
            if let profile = service.qualityProfile(from: sample.source, to: sample.target) {
                row["translation_profile"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
            }
            guard (sample.text != nil) != (sample.fixturePath != nil) else { throw CocoaError(.fileReadCorruptFile) }
            let bytes: Data
            if let path = sample.fixturePath { bytes = try Data(contentsOf: fixture(path)) }
            else if let text = sample.text { bytes = Data(text.utf8) }
            else { throw CocoaError(.fileReadCorruptFile) }
            row["input_sha256"] = hash(bytes)
            var sourceText = sample.text ?? String(data: bytes, encoding: .utf8) ?? ""
            var finalStart = ProcessInfo.processInfo.systemUptime
            var concurrentOutput: String?
            if scenario == .dictation {
                guard request.allowASRPreparation == true, let path = sample.fixturePath else { throw CocoaError(.fileReadNoPermission) }
                if sample.speechRuntimeID == "canary" {
                    guard sample.speechPipeline == "sequential", let modelDirectory = sample.speechModelsDirectory else { throw CocoaError(.fileReadNoPermission) }
                    let samples = try audio(fixture(path))
                    try CanaryQualificationRuntime.validateAudio(samples)
                    try CanaryQualificationRuntime.validateLanguage(sample.source)
                    let snapshotURL = try fixture(modelDirectory + "/snapshot.json")
                    if FileManager.default.fileExists(atPath: snapshotURL.path) {
                        row["canary_snapshot_manifest_sha256"] = hash(try Data(contentsOf: snapshotURL))
                        row["canary_snapshot_contract"] = "hash_of_staged_metadata_only; not_independent_weight_verification"
                    } else { row["canary_snapshot_manifest_status"] = "unavailable" }
                    let loadStart = ProcessInfo.processInfo.systemUptime
                    let canary = try await CanaryQualificationRuntime(modelsDirectory: fixture(modelDirectory), sourceLanguage: sample.source)
                    row["asr_prepare_s"] = ProcessInfo.processInfo.systemUptime - loadStart
                    row["speech_pipeline"] = "sequential"
                    row["speech_profile"] = ["runtime": "canary-coreml-short", "qualification": "unqualified", "model_repository": "FluidInference/canary-1b-v2-coreml", "expected_revision": "75c1b536fe7ca6b589d2395ed9a43169d71f543b", "models_directory": modelDirectory]
                    row["timing_contract"] = "short_clip_batch_after_input_end; no_streaming_or_long_merge_claim"
                    row["audio_seconds"] = Double(samples.count) / 16_000
                    finalStart = ProcessInfo.processInfo.systemUptime
                    sourceText = try await canary.transcribe(audio: samples)
                    row["source_transcript"] = sourceText
                    row["source_utterances"] = [["id": "0", "text": sourceText, "startSample": 0, "endSample": samples.count] as [String: Any]]
                    row["source_utterance_contract"] = "single_short_clip_result"
                } else {
                let mode = DictationMode(rawValue: sample.speechMode ?? "hybrid") ?? .hybrid
                let profile: SpeechRecognitionProfile
                if let runtime = sample.speechRuntimeID { profile = try .candidate(language: sample.source, mode: mode, runtimeID: runtime) }
                else { profile = try .resolve(language: sample.source, mode: mode) }
                row["speech_profile"] = profile.diagnostics
                row["speech_profile_id"] = profile.configurationID
                row["timing_contract"] = "fixed_rate_file_replay_not_microphone; final includes ASR finalization plus subsequent OPUS"
                let speech = SpeechSession(profile: profile, memoryLimit: min(Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.45), 3_500_000_000), modelsRoot: StoragePaths.models)
                session = speech
                speech.onQualificationTelemetry = { measured.speech($0) }
                let loadStart = ProcessInfo.processInfo.systemUptime
                try await speech.load(mode: profile.mode)
                row["asr_prepare_s"] = ProcessInfo.processInfo.systemUptime - loadStart
                row["asr_prepare_contract"] = "model preparation includes any missing asset download; not pure cold load"
                let samples = try audio(fixture(path))
                let pipeline = sample.speechPipeline ?? "concurrent"
                guard ["concurrent", "sequential"].contains(pipeline) else { throw CocoaError(.fileReadCorruptFile) }
                row["speech_pipeline"] = pipeline
                var snapshotContinuation: AsyncStream<CaptionSnapshot>.Continuation?
                var snapshotConsumer: Task<Void, Never>?
                defer { snapshotContinuation?.finish(); snapshotConsumer?.cancel() }
                if pipeline == "concurrent" {
                    let translation = QualityProbeConcurrentTranslation(source: sample.source, target: sample.target, measurements: measured, profileCatalog: catalog, qualityModelsRoots: extraRoots)
                    concurrent = translation
                    let prepareStart = ProcessInfo.processInfo.systemUptime
                    try await translation.prepare()
                    row["translation_prepare_s"] = ProcessInfo.processInfo.systemUptime - prepareStart
                    let warmStart = ProcessInfo.processInfo.systemUptime
                    try await translation.warmUp()
                    row["translation_warmup_s"] = ProcessInfo.processInfo.systemUptime - warmStart
                    row["translation_warmup_contract"] = "load plus synthetic punctuation inference; excluded from scored outputs"
                    row["timing_contract"] = "fixed_rate_file_replay_with_production_concurrent_MT; final includes input backlog drain, ASR finalization and finishUtterances; not microphone latency"
                }
                let archive = QualityProbeSourceArchive()
                let stream = AsyncStream<CaptionSnapshot> { snapshotContinuation = $0 }
                let continuation = snapshotContinuation
                let activeTranslation = concurrent
                speech.onSnapshot = { snapshot, _, _, _ in continuation?.yield(snapshot) }
                snapshotConsumer = Task {
                    for await snapshot in stream {
                        await archive.apply(snapshot)
                        await activeTranslation?.update(snapshot)
                    }
                }
                let replay = try await speech.replayRealtimeForQualification(samples, mode: profile.mode, language: sample.source)
                let telemetry = speech.qualificationSnapshot()
                let asrReturned = ProcessInfo.processInfo.systemUptime
                snapshotContinuation?.finish()
                await snapshotConsumer?.value
                row["speech_telemetry"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(telemetry))
                row["audio_seconds"] = replay.audioSeconds
                row["replay_wall_s"] = replay.wallSeconds
                guard telemetry.correctionFailures == 0 else { throw CocoaError(.coderValueNotFound) }
                sourceText = replay.text
                row["source_transcript"] = sourceText
                let finalSnapshot = await speech.snapshot()
                let utterances = await archive.finish(finalSnapshot, fallback: replay.text, endSample: samples.count)
                row["source_utterances"] = utterances.map { ["id": String($0.id), "text": $0.text, "startSample": $0.startSample, "endSample": $0.endSample] as [String: Any] }
                row["source_utterance_contract"] = "RecordingTranscript_over_all_ordered_caption_snapshots"
                finalStart = asrReturned - (telemetry.finalizationSeconds ?? 0)
                if let concurrent {
                    concurrentOutput = try await concurrent.finish(await speech.snapshot(), fallback: replay.text, endSample: samples.count)
                }
                }
            } else { row["timing_contract"] = "request_to_result_including_model_load" }
            guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scenario == .page else { throw CocoaError(.fileReadCorruptFile) }
            if let concurrentOutput { row["output"] = concurrentOutput }
            else if scenario == .page {
                let page: PageTranslationRequest
                if sample.fixturePath != nil { page = try JSONDecoder().decode(PageTranslationRequest.self, from: bytes) }
                else { page = .init(runId: sample.id, groups: [.init(id: "group", runs: [.init(id: "text", text: sourceText)])], totalCharacters: sourceText.utf16.count) }
                let output = try await PageTranslationProcessor.translate(page, from: sample.source, to: sample.target, engine: textEngine) { _ in }
                row["output_runs"] = output.translations.map { ["id": $0.id, "text": $0.text] }
                row["fallback_groups"] = output.fallbackGroups
            } else { row["output"] = try await textEngine.translate(sourceText, from: sample.source, to: sample.target) }
            row["final_seconds"] = ProcessInfo.processInfo.systemUptime - finalStart
            let passes = await textEngine.recordedPasses()
            if concurrent == nil { row["model_load_seconds"] = passes.reduce(0) { $0 + $1.modelLoadSeconds } }
            row["model_load_contract"] = concurrent == nil ? "sum_of_actual_per_leg_lookup_and_load; pivot_can_reload_between_legs" : "production_session_does_not_expose_per_leg_loads; see_prepare_and_warmup_timings"
            row["passes"] = passes.map { ["source": $0.pair.source, "target": $0.pair.target, "model_id": $0.modelID ?? "unknown", "used_quality": $0.usedQuality, "seconds": $0.seconds, "model_load_seconds": $0.modelLoadSeconds] as [String: Any] }
            row["status"] = "succeeded"
        } catch { row["status"] = "failed"; row["error"] = String(describing: error) }
        await session?.close()
        await concurrent?.close()
        await engine?.unload()
        sampler?.cancel(); await sampler?.value
        if let observer { NotificationCenter.default.removeObserver(observer) }
        measurements?.sample()
        if let measurements { row["measurements"] = measurements.summary(); measurements.close() }
        try write(row, to: rowURL)
    }
}
#endif
