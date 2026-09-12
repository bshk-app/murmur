import AVFoundation
import CryptoKit
import Darwin
import Foundation
import MLX
import MurmurKit

/// Host-only measurements of the production phone engines. These observations
/// explain allocations; they do not qualify iPhone memory or latency budgets.
enum MemoryProbe {
    private struct Sample: Codable {
        let seconds: Double
        let phase: String
        let processBytes: UInt64
        let lifetimePeakBytes: Int64
        let mlxActiveBytes: Int
        let mlxCacheBytes: Int
        let mlxPeakBytes: Int
    }
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private let start = ProcessInfo.processInfo.systemUptime
        private var phase = "start"
        private var samples: [Sample] = []
        private var failures: [String] = []
        func failure(_ value: String) { lock.lock(); failures.append(value); lock.unlock() }
        func takeFailures() -> [String] {
            lock.lock(); defer { lock.unlock() }
            let result = failures; failures.removeAll(); return result
        }
        func mark(_ value: String) { lock.lock(); phase = value; lock.unlock(); sample() }
        func sample() {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard status == KERN_SUCCESS else { return }
            let active = Memory.activeMemory, cached = Memory.cacheMemory, peak = Memory.peakMemory
            lock.lock(); defer { lock.unlock() }
            samples.append(.init(seconds: ProcessInfo.processInfo.systemUptime - start, phase: phase,
                processBytes: info.phys_footprint, lifetimePeakBytes: info.ledger_phys_footprint_peak,
                mlxActiveBytes: active, mlxCacheBytes: cached, mlxPeakBytes: peak))
        }
        func data() throws -> Data { lock.lock(); defer { lock.unlock() }; return try JSONEncoder().encode(samples) }
    }

    @MainActor static func run(arguments: [String]) async throws {
        func option(_ name: String, _ fallback: String) -> String {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return fallback }
            return arguments[i + 1]
        }
        let wav = URL(fileURLWithPath: option("--wav", ""))
        let output = URL(fileURLWithPath: option("--json-out", "/tmp/murmur-memory.json"))
        let root = URL(fileURLWithPath: option("--models-root", "/tmp/murmur-memory-models"))
        let cacheMB = Int(option("--cache-mb", "-1")) ?? -1
        guard let mode = DictationMode(rawValue: option("--probe-mode", "hybrid")) else { throw CocoaError(.fileReadCorruptFile) }
        let trim = arguments.contains("--trim-after-load")
        let hashOnly = arguments.contains("--hash-only")
        let poolHash = arguments.contains("--pool-hash")
        let file = try AVAudioFile(forReading: wav)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              file.length > 0, file.length <= 16_000 * 60,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        let audio = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        GPU.set(memoryLimit: 3_500_000_000, relaxed: false)
        if cacheMB >= 0 { Memory.cacheLimit = cacheMB * 1024 * 1024 }
        let actualCacheLimit = Memory.cacheLimit
        let recorder = Recorder()
        let sampler = Task.detached {
            while !Task.isCancelled { recorder.sample(); try? await Task.sleep(for: .milliseconds(20)) }
        }
        let speech = SpeechSession(quantization: "int4", ane: true, memoryLimit: 3_500_000_000,
                                   corrector: .gigaam, modelsRoot: root)
        let translation = TranslationSession(modelsRoot: root)
        var runs: [[String: Any]] = []
        var phases: [[String: Any]] = []
        var failure: String?
        var modelIdentity: String?
        func phase(_ name: String, _ operation: () async throws -> Void) async throws {
            recorder.mark(name)
            let start = ProcessInfo.processInfo.systemUptime
            try await operation()
            recorder.mark(name + "-ready")
            phases.append(["name": name, "seconds": ProcessInfo.processInfo.systemUptime - start])
            print("memory-probe: \(name) ready")
        }
        do {
            if hashOnly {
                try await phase("identity-check") {
                    let directory = root.appendingPathComponent("ct2-ruen")
                    if poolHash { modelIdentity = try autoreleasepool { try TranslationModelIdentity.compute(directory: directory) } }
                    else { modelIdentity = try TranslationModelIdentity.compute(directory: directory) }
                }
            } else {
            if mode != .accurate {
                try await phase("nemotron-and-vad-load") { try await speech.load(mode: .fast) }
            }
            if trim { recorder.mark("trim-mlx-cache"); Memory.clearCache(); recorder.mark("trim-mlx-cache-ready") }
            if mode != .fast {
                try await phase(mode == .accurate ? "vad-and-gigaam-load" : "gigaam-load") { try await speech.load(mode: mode) }
            }
            try await phase("preview-mt-load") { try await translation.prepare(from: "ru", to: "en") }
            try await phase("opus-mt-load") { try await translation.warmUp(from: "ru", to: "en") }
            for repetition in 0..<3 {
                recorder.mark("replay-\(repetition)")
                let (stream, continuation) = AsyncStream<CaptionSnapshot>.makeStream()
                speech.onSnapshot = { snapshot, _, _, _ in continuation.yield(snapshot) }
                let consumer = Task {
                    for await snapshot in stream {
                        await translation.update(snapshot, from: "ru", to: "en", onUpdate: { _ in },
                                                 onFailure: { recorder.failure($0) })
                    }
                }
                let result: SpeechReplayResult
                do { result = try await speech.replayRealtimeForQualification(audio, mode: mode, language: "ru") }
                catch { continuation.finish(); consumer.cancel(); await consumer.value; throw error }
                continuation.finish()
                await consumer.value
                let errors = recorder.takeFailures()
                let translated = try await translation.finish(result.text, from: "ru", to: "en")
                runs.append(["repetition": repetition, "transcript": result.text, "translation": translated,
                    "wall_seconds": result.wallSeconds, "compute_seconds": result.computeSeconds,
                    "translation_errors": errors])
                recorder.mark("replay-\(repetition)-ready")
            }
            }
        } catch { failure = String(describing: error) }
        recorder.mark("unload-mt"); await translation.unload(); recorder.mark("unload-mt-ready")
        recorder.mark("unload-speech"); await speech.close(); recorder.mark("unload-speech-ready")
        sampler.cancel(); await sampler.value
        let samples = try JSONSerialization.jsonObject(with: recorder.data())
        var report: [String: Any] = ["schema_version": 1, "evidence_kind": "host_memory_diagnostic",
            "device": "Mac", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "mlx_memory_limit_bytes": 3_500_000_000, "mlx_cache_limit_bytes": actualCacheLimit,
            "speech_mode": mode.rawValue,
            "hash_only": hashOnly, "pool_hash": poolHash,
            "trim_after_load": trim, "sample_interval_ms": 20, "audio_seconds": Double(audio.count) / 16000,
            "input_sha256": SHA256.hash(data: try Data(contentsOf: wav)).map { String(format: "%02x", $0) }.joined(),
            "phases": phases, "runs": runs, "samples": samples,
            "limitations": "Mac Core ML/Metal allocations differ from iPhone; sampled peaks and process lifetime peaks have different scopes."]
        report["status"] = failure == nil ? "complete" : "failed"
        report["model_identity"] = modelIdentity
        if let failure { report["error"] = failure }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        if failure != nil { throw CocoaError(.coderValueNotFound) }
    }
}
