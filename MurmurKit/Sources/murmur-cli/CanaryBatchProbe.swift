import Foundation
import CryptoKit
import MurmurKit

enum CanaryBatchProbe {
    struct Row: Codable, Sendable {
        let startSample: Int
        let endSample: Int
        let source: String
        let translation: String?
    }
    private actor Results {
        var rows: [Row] = []
        func append(_ row: Row) { rows.append(row) }
    }
    @MainActor static func run(arguments: [String]) async throws {
        func option(_ name: String, _ fallback: String) -> String {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return fallback }
            return arguments[i + 1]
        }
        let original = URL(fileURLWithPath: option("--wav", ""))
        let output = URL(fileURLWithPath: option("--json-out", "/tmp/canary-batch.json"))
        let source = option("--source", "ru"), target = option("--target", "en")
        let repetitions = Int(option("--repeat-audio", "1")) ?? 1
        guard (1...10).contains(repetitions) else { throw CocoaError(.fileReadCorruptFile) }
        var input = original
        if repetitions > 1 {
            input = output.deletingPathExtension().appendingPathExtension("wav")
            let writer = try PCMRecordingWriter(url: input)
            for _ in 0..<repetitions {
                let reader = try AudioFilePCMReader(url: original)
                while let chunk = try reader.next() { try writer.append(chunk) }
                try writer.append([Float](repeating: 0, count: 8_000))
            }
            try writer.finish()
        }
        let direct = source != target && CanaryRuntime.supportsTranslation(source: source, target: target)
        let processor = CanaryTranscriber()
        let translation = TextTranslationSession(modelsRoot: URL(fileURLWithPath: option("--translation-models", "/tmp/canary-batch-mt")))
        let results = Results()
        let prepareStart = ProcessInfo.processInfo.systemUptime
        try await processor.prepare()
        if source != target && !direct { try await translation.prepare(from: source, to: target) { _ in } }
        let prepared = ProcessInfo.processInfo.systemUptime
        var failure: String?
        do {
            try await processor.processFile(url: input, source: source, target: direct ? target : nil,
                onBatch: { range, result in
                    var text = result.translatedText
                    if source != target && !direct { text = try await translation.translate(result.sourceText, from: source, to: target) }
                    try Task.checkCancellation()
                    await results.append(.init(startSample: range.lowerBound, endSample: range.upperBound,
                                               source: result.sourceText, translation: text))
                })
        } catch { failure = String(describing: error) }
        let finished = ProcessInfo.processInfo.systemUptime
        await processor.close(); await translation.unload()
        let rows = await results.rows
        var previousEnd = 0
        for row in rows {
            guard row.startSample >= previousEnd, row.endSample > row.startSample,
                  row.endSample - row.startSample <= CanaryRuntime.maxSamples else { throw CocoaError(.fileReadCorruptFile) }
            previousEnd = row.endSample
        }
        let duration = try AudioFilePCMReader(url: input).duration
        var report: [String: Any] = ["schema_version": 1, "evidence_kind": "canary_batch_execution_smoke",
            "host": "Mac", "source_language": source, "target_language": target,
            "route": direct ? "canary-direct" : source == target ? "canary-asr" : "canary-asr-opus",
            "audio_seconds": duration, "maximum_window_samples": CanaryRuntime.maxSamples,
            "prepare_seconds": prepared - prepareStart, "processing_seconds": finished - prepared,
            "batches": try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)),
            "status": failure == nil && !rows.isEmpty ? "complete" : "failed",
            "input_sha256": try digest(input)]
        if let failure { report["error"] = failure }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        guard failure == nil, !rows.isEmpty else { throw CocoaError(.coderValueNotFound) }
        print("Canary batch report: \(output.path)")
    }
    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var value = SHA256()
        while try autoreleasepool(invoking: {
            let bytes = try file.read(upToCount: 1_048_576) ?? Data()
            value.update(data: bytes)
            return !bytes.isEmpty
        }) {}
        return value.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
