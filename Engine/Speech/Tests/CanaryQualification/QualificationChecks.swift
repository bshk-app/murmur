import Foundation
import AVFoundation
import Darwin
import CryptoKit

@main struct QualificationChecks {
    static func rejects(_ check: () throws -> Void) {
        do { try check(); fatalError("Expected validation failure") } catch {}
    }
    static func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        precondition(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    static func checkAssetLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let blob = root.appendingPathComponent("blob")
        let snapshot = root.appendingPathComponent("snapshot-link")
        let linked = root.appendingPathComponent("staged")
        let bytes = Data("immutable pinned model bytes".utf8)
        try bytes.write(to: blob)
        try fm.createSymbolicLink(at: snapshot, withDestinationURL: blob)
        try CanaryAssets.stageFile(from: snapshot, to: linked)
        let original = try fm.attributesOfItem(atPath: blob.path)
        let staged = try fm.attributesOfItem(atPath: linked.path)
        precondition(original[.systemFileNumber] as? UInt64 == staged[.systemFileNumber] as? UInt64)
        precondition(staged[.type] as? FileAttributeType == .typeRegular)
        for code in [EXDEV, ENOTSUP] {
            let copied = root.appendingPathComponent("copy-\(code)")
            try CanaryAssets.stageFile(from: snapshot, to: copied, linkOperation: { source, _ in
                precondition(source == blob.resolvingSymlinksInPath()); return code
            })
            let copyBytes = try Data(contentsOf: copied)
            precondition(copyBytes == bytes)
            let attributes = try fm.attributesOfItem(atPath: copied.path)
            precondition(original[.systemFileNumber] as? UInt64 != attributes[.systemFileNumber] as? UInt64)
        }
        let denied = root.appendingPathComponent("denied")
        rejects { try CanaryAssets.stageFile(from: snapshot, to: denied, linkOperation: { _, _ in EACCES }) }
        precondition(!fm.fileExists(atPath: denied.path))
        rejects { try CanaryAssets.stageFile(from: root, to: root.appendingPathComponent("directory")) }
        try fm.removeItem(at: snapshot); try fm.removeItem(at: blob)
        let remainingBytes = try Data(contentsOf: linked)
        precondition(remainingBytes == bytes)
        print("Asset staging: resolved regular hardlink, EXDEV/unsupported copy, permission refusal, cache removal checks passed")
    }

    static func checkCorruptCacheRecovery() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cached = root.appendingPathComponent("cached")
        let published = root.appendingPathComponent("published")
        try fm.createDirectory(at: published, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let expected = Data("good".utf8), corrupt = Data("BAD!".utf8)
        let asset = CanaryAssets.Asset(path: "model.bin", bytes: expected.count,
            sha256: SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined())
        let oldURL = published.appendingPathComponent(asset.path)
        try expected.write(to: oldURL)
        let publishedInode = try fm.attributesOfItem(atPath: oldURL.path)[.systemFileNumber] as! UInt64
        try corrupt.write(to: cached)
        for freshIsGood in [false, true] {
            let staging = root.appendingPathComponent("stage-\(freshIsGood)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            var fetches = 0
            do {
                try await CanaryAssets.stageVerified(asset, from: cached, to: staging.appendingPathComponent(asset.path)) { requested, fresh in
                    precondition(requested.path == asset.path)
                    fetches += 1
                    try (freshIsGood ? expected : corrupt).write(to: fresh)
                }
                precondition(freshIsGood)
                try CanaryAssets.publish(staging, at: published)
            } catch let error as CocoaError where error.code == .fileReadCorruptFile {
                precondition(!freshIsGood)
            }
            precondition(fetches == 1)
            let oldBytes = try Data(contentsOf: oldURL)
            precondition(oldBytes == expected)
            let resultingInode = try fm.attributesOfItem(atPath: oldURL.path)[.systemFileNumber] as! UInt64
            precondition((resultingInode == publishedInode) == !freshIsGood)
            let cacheBytes = try Data(contentsOf: cached)
            precondition(cacheBytes == corrupt) // Shared cached inode was never overwritten.
        }
        let validStage = root.appendingPathComponent("valid-stage")
        try await CanaryAssets.stageVerified(asset, from: oldURL, to: validStage) { _, _ in
            fatalError("Valid cache must not trigger fresh fetch")
        }
        print("Corrupt cache: fresh verified recovery, bad fresh preserves publication, valid cache skips fetch checks passed")
    }

    static func checkNestedPublicationSwap() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let published = root.appendingPathComponent("published")
        let staging = root.appendingPathComponent("staging")
        defer { try? fm.removeItem(at: root) }
        let old = ["Encoder.mlmodelc/weights/weight.bin": "old encoder",
                   "Decoder.mlmodelc/weights/weight.bin": "old decoder", ".ready": "old pin"]
        let new = ["Encoder.mlmodelc/weights/weight.bin": "new encoder",
                   "Decoder.mlmodelc/weights/weight.bin": "new decoder",
                   "Projection.mlmodelc/model.mil": "new projection", ".ready": "new pin"]
        func put(_ tree: [String: String], at directory: URL) throws {
            for (path, text) in tree {
                let file = directory.appendingPathComponent(path)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
            }
        }
        func read(_ inputDirectory: URL) throws -> [String: String] {
            let directory = inputDirectory.resolvingSymlinksInPath()
            var tree: [String: String] = [:]
            let entries = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let file as URL in entries where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                tree[file.resolvingSymlinksInPath().pathComponents.dropFirst(directory.pathComponents.count).joined(separator: "/")] = try String(contentsOf: file, encoding: .utf8)
            }
            return tree
        }
        try put(old, at: published)
        try put(["Encoder.mlmodelc/weights/weight.bin": "partial candidate"], at: staging)
        let duringPreparation = try read(published)
        precondition(duringPreparation == old, "Unexpected tree: \(duringPreparation)")
        try put(new, at: staging)
        let beforeSwap = try read(published), completeCandidate = try read(staging)
        precondition(beforeSwap == old && completeCandidate == new)
        try CanaryAssets.publish(staging, at: published)
        let installed = try read(published), swappedOld = try read(staging)
        precondition(installed == new && swappedOld == old)
        try fm.removeItem(at: staging)
        let afterCleanup = try read(published)
        precondition(afterCleanup == new)
        print("Nested publication: old tree intact during preparation, atomic exchange yields complete new tree, old staging cleanup preserves publication")
    }

    static func main() async throws {
        try checkAssetLinks()
        try await checkCorruptCacheRecovery()
        try checkNestedPublicationSwap()
        precondition(CanaryQualificationRuntime.supportedLanguages.count == 25)
        for source in CanaryRuntime.supportedLanguages {
            for target in CanaryRuntime.supportedLanguages {
                precondition(CanaryRuntime.supportsTranslation(source: source, target: target)
                    == (source != target && (source == "en" || target == "en")))
            }
        }
        precondition(!CanaryRuntime.supportsTranslation(source: "xx", target: "en"))
        // A size-only UI hint cannot authorize model loading: all sparse placeholders
        // have expected sizes, but bounded hash verification must reject their bytes.
        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        for asset in CanaryAssets.files {
            let url = corrupt.appendingPathComponent(asset.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(asset.bytes)); try handle.close()
        }
        try Data(CanaryAssets.revision.utf8).write(to: corrupt.appendingPathComponent(".ready"))
        precondition(CanaryAssets.isReady(at: corrupt))
        rejects { try CanaryAssets.verify(at: corrupt) }
        if let verifyDirectory = ProcessInfo.processInfo.environment["CANARY_VERIFY_DIRECTORY"] {
            try CanaryAssets.verify(at: URL(fileURLWithPath: verifyDirectory))
            print("All pinned asset bytes and SHA256 verified")
        }
        for language in CanaryQualificationRuntime.supportedLanguages { try CanaryQualificationRuntime.validateLanguage(language) }
        rejects { try CanaryQualificationRuntime.validateLanguage("nb") }
        rejects { try CanaryQualificationRuntime.validateLanguage("EN") }
        rejects { try CanaryQualificationRuntime.validateAudio([]) }
        rejects { try CanaryQualificationRuntime.validateAudio([Float.nan]) }
        rejects { try CanaryQualificationRuntime.validateAudio([Float.infinity]) }
        rejects { try CanaryQualificationRuntime.validateAudio([1.01]) }
        rejects { try CanaryQualificationRuntime.validateAudio(Array(repeating: 0, count: 240001)) }
        try CanaryQualificationRuntime.validateAudio(Array(repeating: 0, count: 240000))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var pieces = Array(repeating: "unused", count: 16384)
        for (index, language) in CanaryQualificationRuntime.supportedLanguages.sorted().enumerated() { pieces[100 + index] = "<|\(language)|>" }
        try JSONSerialization.data(withJSONObject: pieces).write(to: temporary)
        let tokenizer = try CanaryQualificationTokenizer(url: temporary)
        for language in CanaryQualificationRuntime.supportedLanguages {
            let prompt = try tokenizer.prompt(source: language, target: language)
            precondition(prompt.count == 10 && prompt[4] == prompt[5])
            precondition(pieces[Int(prompt[4])] == "<|\(language)|>")
            precondition(prompt.enumerated().allSatisfy { [4, 5].contains($0.offset) || $0.element == CanaryQualificationConfig.promptEnTranscribePnc[$0.offset] })
        }
        rejects { _ = try tokenizer.prompt(source: "nb", target: "nb") }
        precondition(canaryQualificationFloat16BitsToFloat(0x3800) == 0.5)
        print("Canary short-window, language, PCM, prompt and float16 checks passed")
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--matrix" {
            let modelDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
            let fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[3])
            let started = ProcessInfo.processInfo.systemUptime
            let runtime = try await CanaryRuntime(modelsDirectory: modelDirectory)
            let loadSeconds = ProcessInfo.processInfo.systemUptime - started
            var rows: [[String: Any]] = []
            for (source, target, file) in [("ru", "en", "ru_ru_01.wav"), ("en", "fi", "en_us_00.wav"),
                ("en", "ru", "en_us_00.wav"), ("en", "de", "en_us_00.wav"), ("en", "fr", "en_us_00.wav"),
                ("fi", "en", "fi_fi_02.wav"), ("de", "en", "de_de_01.wav"), ("fr", "en", "fr_fr_00.wav")] {
                let samples = try readSamples(fixtureDirectory.appendingPathComponent(file))
                let start = ProcessInfo.processInfo.systemUptime
                let output = try await runtime.process(audio: samples, sourceLanguage: source, targetLanguage: target)
                precondition(!output.sourceText.isEmpty && !(output.translatedText ?? "").isEmpty)
                rows.append(["source": source, "target": target, "fixture": file,
                             "samples": samples.count, "seconds": ProcessInfo.processInfo.systemUptime - start,
                             "source_text": output.sourceText, "direct_translation": output.translatedText!])
            }
            // Unsupported routing and cancellation must fail before inference or outputs.
            do { _ = try await runtime.process(audio: [0], sourceLanguage: "ru", targetLanguage: "fi"); fatalError("accepted unsupported pair") }
            catch CanaryRuntime.Failure.unsupportedTranslation("ru", "fi") {}
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await runtime.process(audio: [0], sourceLanguage: "en")
            }
            do { _ = try await cancelled.value; fatalError("accepted cancellation") } catch is CancellationError {}
            let result: [String: Any] = ["evidence": "execution-smoke-only; no translation reference or qualification",
                "model_revision": CanaryAssets.revision, "load_seconds": loadSeconds,
                "model_load_count": 1, "compute_units": "preprocessor CPU; encoder/decoder/projection CPU+GPU",
                "rows": rows]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
            print("Eight direct translation routes passed on one loaded runtime; unsupported pair and cancellation rejected")
            return
        }
        guard CommandLine.arguments.count >= 4 else { return }
        let modelDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
        let audioURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let language = CommandLine.arguments[3]
        let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        precondition(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        try CanaryQualificationRuntime.validateAudio(samples)
        let runtime = try await CanaryRuntime(modelsDirectory: modelDirectory)
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await runtime.process(audio: samples, sourceLanguage: language, targetLanguage: CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : nil)
        precondition(!result.sourceText.isEmpty)
        print("ASR/AST \(language), samples=\(samples.count), seconds=\(ProcessInfo.processInfo.systemUptime-start): \(result)")
    }
}
