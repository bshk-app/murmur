import Foundation
import XCTest
@testable import MurmurKit

final class TranslationDownloaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Manifest

    /// The pinned manifest must cover every direction the router can produce,
    /// or a language pair the picker offers will fail at download time.
    func testEveryRoutableDirectionIsPinned() {
        var unpinned: [String] = []
        for source in LanguagePair.supportedLanguages {
            for target in LanguagePair.supportedLanguages where source != target {
                guard let route = LanguagePair.route(from: source, to: target) else { continue }
                let legs: [LanguagePair]
                switch route {
                case .direct(let pair): legs = [pair]
                case .pivot(let first, let second): legs = [first, second]
                }
                for pair in legs where TranslationModelDigests.all["\(pair.source)\(pair.target)"] == nil {
                    unpinned.append("\(pair.source)\(pair.target)")
                }
            }
        }
        XCTAssertEqual(Set(unpinned), [], "routable directions with no pinned digests")
    }

    /// Guards the property the whole design rests on: no artifact may reach the
    /// network without something to check it against.
    func testEveryArtifactCarriesADigest() throws {
        let pair = try XCTUnwrap(LanguagePair(source: "ru", target: "en"))
        for artifact in try TranslationDownloader.artifacts(for: pair) {
            XCTAssertEqual(artifact.sha256.count, 64, "\(artifact.localName) digest is not a sha256")
        }
    }

    func testUnpinnedDirectionIsRefused() throws {
        let pair = try XCTUnwrap(LanguagePair(source: "zz", target: "yy"))
        XCTAssertThrowsError(try TranslationDownloader.artifacts(for: pair)) { error in
            XCTAssertEqual(error as? TranslationDownloader.Err, .unpinnedDirection("zzyy"))
        }
    }

    // MARK: - Verification

    func testVerifyAcceptsMatchingDigest() {
        let data = Data("murmur".utf8)
        let digest = "6200f53485b683973d0c8cb0da433414326ca268363546ece184689555b06568"
        XCTAssertNoThrow(
            try TranslationDownloader.verify(data, against: digest, file: "x"))
    }

    func testVerifyRejectsWrongDigest() {
        let data = Data("murmur".utf8)
        XCTAssertThrowsError(
            try TranslationDownloader.verify(data, against: String(repeating: "0", count: 64),
                                             file: "model.bin")
        ) { error in
            guard case .digestMismatch(let file, _, _)? = error as? TranslationDownloader.Err else {
                return XCTFail("expected digestMismatch, got \(error)")
            }
            XCTAssertEqual(file, "model.bin")
        }
    }

    // MARK: - Gzip

    func testGunzipRoundTripsRealGzipData() throws {
        // Built with the system gzip so the fixture exercises a real header
        // rather than one this test also wrote.
        let payload = String(repeating: "translate me, please. ", count: 5000)
        let plain = root.appendingPathComponent("payload.txt")
        try payload.write(to: plain, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-k", "-f", plain.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let gzipped = try Data(contentsOf: plain.appendingPathExtension("gz"))
        let restored = try TranslationDownloader.gunzip(gzipped, file: "payload.txt")
        XCTAssertEqual(String(data: restored, encoding: .utf8), payload)
    }

    func testGunzipRejectsNonGzip() {
        let data = Data(repeating: 0x41, count: 64)
        XCTAssertThrowsError(try TranslationDownloader.gunzip(data, file: "x")) { error in
            XCTAssertEqual(error as? TranslationDownloader.Err, .notGzip(file: "x"))
        }
    }

    // MARK: - Layout

    func testWriteConfigMatchesEngineExpectations() throws {
        let pair = try XCTUnwrap(LanguagePair(source: "fi", target: "en"))
        let directory = root.appendingPathComponent(pair.modelDirectoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try TranslationDownloader.writeConfig(for: pair, into: directory)

        let yaml = try String(contentsOf: directory.appendingPathComponent("config.bergamot.yml"),
                              encoding: .utf8)
        XCTAssertTrue(yaml.contains("model.fien.intgemm.alphas.bin"))
        XCTAssertTrue(yaml.contains("vocab.fien.spm"))
        XCTAssertTrue(yaml.contains("lex.50.50.fien.s2t.bin"))
        XCTAssertTrue(yaml.contains("relative-paths: true"))
        XCTAssertTrue(yaml.contains("gemm-precision: int8shiftAlphaAll"))
    }

    /// A directory missing any one file must not read as installed, or the
    /// engine is asked to load a model that is not there.
    func testIsInstalledRequiresEveryFile() throws {
        let pair = try XCTUnwrap(LanguagePair(source: "ru", target: "en"))
        let directory = root.appendingPathComponent(pair.modelDirectoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertFalse(TranslationDownloader.isInstalled(pair: pair, in: root))

        for artifact in try TranslationDownloader.artifacts(for: pair) {
            try Data().write(to: directory.appendingPathComponent(artifact.localName))
        }
        // Files present but no config — still incomplete.
        XCTAssertFalse(TranslationDownloader.isInstalled(pair: pair, in: root))

        try TranslationDownloader.writeConfig(for: pair, into: directory)
        XCTAssertTrue(TranslationDownloader.isInstalled(pair: pair, in: root))
    }

    /// The only test that proves the whole chain: fetch from the mirror, verify
    /// against the pinned digests, publish the directory, and have the engine
    /// load it and translate. Opt-in because it needs the network and ~20 MB.
    ///
    ///     MURMUR_NETWORK_TESTS=1 swift test --filter testEndToEndDownloadAndTranslate
    func testEndToEndDownloadAndTranslate() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MURMUR_NETWORK_TESTS"] == "1",
                          "set MURMUR_NETWORK_TESTS=1 to run")
        let pair = try XCTUnwrap(LanguagePair(source: "ru", target: "en"))
        let directory = try await TranslationDownloader.download(pair: pair, into: root)

        XCTAssertTrue(TranslationDownloader.isInstalled(pair: pair, in: root))
        XCTAssertEqual(directory.lastPathComponent, "moz-ruen")

        let translator = try Translator(pair: pair, modelsRoot: root)
        let output = try translator.translate("Я отправлю документы завтра.")
        XCTAssertFalse(output.isEmpty)
        XCTAssertTrue(output.lowercased().contains("tomorrow"),
                      "unexpected translation: \(output)")
    }

    // MARK: - Progress

    /// The bug this guards: progress used to be `fileIndex / 3`, so a 22 MB
    /// model reported nothing at all until it finished and then jumped a third.
    /// A fake transport delivers known chunks, so the assertions are exact and
    /// need no network.
    func testProgressAdvancesWithinASingleFile() async throws {
        let pair = try XCTUnwrap(LanguagePair(source: "ru", target: "en"))
        let pinned = try XCTUnwrap(TranslationModelDigests.all["ruen"])

        let seen = Recorder()
        let fetcher: TranslationDownloader.Fetch = { url, onBytes in
            // Ten ticks per file, so a file that reports only on completion
            // would produce three fractions instead of thirty.
            let total = Self.pinnedSize(for: url.lastPathComponent, in: pinned)
            for step in 1 ... 10 {
                onBytes(Int64(total * step / 10))
            }
            throw CancellationError()   // stop before digest checks; progress is the subject
        }

        _ = try? await TranslationDownloader.download(
            pair: pair, into: root, fetcher: fetcher,
            onProgress: { progress in seen.record(progress) })

        // Let the queued main-actor hops drain.
        try await Task.sleep(nanoseconds: 200_000_000)

        let fractions = seen.fractions()
        XCTAssertGreaterThan(fractions.count, 5,
                             "expected many intermediate ticks, got \(fractions)")
        // The decisive property: something is reported strictly between the
        // start and the end of the very first file.
        let firstFileShare = Double(pinned.model.downloadBytes) / Double(pinned.totalDownloadBytes)
        XCTAssertTrue(fractions.contains { $0 > 0 && $0 < firstFileShare },
                      "no progress inside the first file; fractions: \(fractions)")
        XCTAssertEqual(fractions, fractions.sorted(), "progress went backwards")
        XCTAssertTrue(fractions.allSatisfy { $0 <= 1.0 }, "progress exceeded 1.0")
    }

    /// Totals come from the manifest, so the denominator is known before the
    /// first byte rather than guessed from the first response.
    func testTotalBytesMatchesTheManifest() throws {
        let pinned = try XCTUnwrap(TranslationModelDigests.all["ruen"])
        let pair = try XCTUnwrap(LanguagePair(source: "ru", target: "en"))
        let sum = try TranslationDownloader.artifacts(for: pair)
            .reduce(0) { $0 + $1.downloadBytes }
        XCTAssertEqual(sum, pinned.totalDownloadBytes)
        XCTAssertGreaterThan(sum, 0)
    }

    /// The regression this guards: weighting each leg equally. With legs of
    /// 17 and 43 MB, finishing the first is 28% of the work, not 50%.
    func testPivotLegsAreWeightedByBytesNotCount() {
        let combined = CombinedDownloadProgress(legBytes: [17_000_000, 43_000_000])
        XCTAssertEqual(combined.totalBytes, 60_000_000)

        // First leg complete == start of the second.
        let boundary = combined.at(leg: 1, received: 0)
        XCTAssertEqual(boundary.receivedBytes, 17_000_000)
        XCTAssertEqual(boundary.fraction, 17.0 / 60.0, accuracy: 0.0001)
        XCTAssertNotEqual(boundary.fraction, 0.5, accuracy: 0.01,
                          "legs weighted by count instead of bytes")

        // Byte counters are cumulative, so the label never resets mid-pivot.
        let midSecond = combined.at(leg: 1, received: 21_500_000)
        XCTAssertEqual(midSecond.receivedBytes, 38_500_000)
        XCTAssertGreaterThan(midSecond.fraction, boundary.fraction)

        let end = combined.at(leg: 2, received: 0)
        XCTAssertEqual(end.fraction, 1.0, accuracy: 0.0001)
    }

    func testCombinedProgressClampsHostileInput() {
        let combined = CombinedDownloadProgress(legBytes: [100, 100])
        // A mirror re-compressing the same verified content may send more than
        // pinned; the bar must not exceed 1.0.
        XCTAssertEqual(combined.at(leg: 1, received: 999).fraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(combined.at(leg: 0, received: -5).receivedBytes, 0)
        XCTAssertEqual(CombinedDownloadProgress(legBytes: []).at(leg: 0, received: 10).fraction, 0)
    }

    /// The manifest must actually supply both legs of a real pivot, or the
    /// weighting above has nothing to weigh.
    func testRealPivotHasBothLegsPinned() throws {
        let route = try XCTUnwrap(LanguagePair.route(from: "fi", to: "de"))
        guard case .pivot(let first, let second) = route else {
            return XCTFail("expected fi->de to pivot, got \(route)")
        }
        XCTAssertNotNil(TranslationDownloader.expectedDownloadBytes(for: first))
        XCTAssertNotNil(TranslationDownloader.expectedDownloadBytes(for: second))
    }

    private static func pinnedSize(for remote: String,
                                   in entry: TranslationModelDigests.Entry) -> Int {
        if remote.hasPrefix("model.") { return entry.model.downloadBytes }
        if remote.hasPrefix("vocab.") { return entry.vocab.downloadBytes }
        return entry.lexicon.downloadBytes
    }

    /// Collects progress snapshots from the main actor.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []

        func record(_ progress: TranslationDownloader.Progress) {
            lock.lock(); defer { lock.unlock() }
            values.append(progress.fraction)
        }

        func fractions() -> [Double] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }
    func testMirrorDirectoryNaming() {
        XCTAssertEqual(TranslationDownloader.Source.mozillaMirror.directoryName("ruen"), "ru-en")
        XCTAssertEqual(TranslationDownloader.Source.mozillaMirror.directoryName("enpt"), "en-pt")
    }
}

// MARK: - Sharing and cancellation

final class TranslationDownloadSharingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Two callers wanting the same direction must pull it once, not twice.
    func testConcurrentCallersShareOneDownload() async throws {
        let pair = try XCTUnwrap(LanguagePair(source: "ru", target: "en"))
        let calls = Counter()
        let fetcher: TranslationDownloader.Fetch = { _, _ in
            await calls.bump()
            // Long enough that the second caller certainly joins the first.
            try await Task.sleep(nanoseconds: 300_000_000)
            throw CancellationError()
        }

        async let first: () = attempt(pair: pair, fetcher: fetcher)
        async let second: () = attempt(pair: pair, fetcher: fetcher)
        _ = await (first, second)

        let count = await calls.value
        XCTAssertEqual(count, 1, "expected one shared fetch, saw \(count)")
    }

    /// Abandoning the only waiter must stop the transfer, not merely stop
    /// waiting for it — otherwise switching language keeps the old one running.
    func testCancellingTheLastWaiterCancelsTheWork() async throws {
        let pair = try XCTUnwrap(LanguagePair(source: "ru", target: "en"))
        let observed = Flag()
        let fetcher: TranslationDownloader.Fetch = { _, _ in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                await observed.raise()   // cancellation reached the transport
                throw error
            }
            return Data()
        }

        let task = Task { await self.attempt(pair: pair, fetcher: fetcher) }
        try await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()
        _ = await task.value
        try await Task.sleep(nanoseconds: 250_000_000)

        let reached = await observed.value
        XCTAssertTrue(reached, "cancellation never reached the download")
    }

    /// Pick a language, switch away, pick it again — the invariant tested
    /// directly, because the window it closes (a cancelled entry still listed
    /// while `leave` is mid-hop) cannot be hit reliably by sleeping.
    ///
    /// Joining a cancelled task would hand back one that fails instantly, so
    /// the model would silently never download and nothing would say so.
    func testJoinNeverReusesACancelledTask() async throws {
        let coordinator = TranslationDownloader.Coordinator()
        let slow: @Sendable () async throws -> URL = {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return URL(fileURLWithPath: "/tmp")
        }
        let (first, _) = await coordinator.join(key: "k", work: slow)
        first.cancel()
        let (second, _) = await coordinator.join(key: "k", work: slow)
        XCTAssertNotEqual(first, second, "join handed back the cancelled task")
        second.cancel()
    }

    /// A live task, by contrast, must be shared rather than duplicated.
    func testJoinReusesALiveTask() async throws {
        let coordinator = TranslationDownloader.Coordinator()
        let slow: @Sendable () async throws -> URL = {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return URL(fileURLWithPath: "/tmp")
        }
        let (first, _) = await coordinator.join(key: "k", work: slow)
        let (second, _) = await coordinator.join(key: "k", work: slow)
        XCTAssertEqual(first, second, "a live task should be shared")
        first.cancel()
    }

    private func attempt(pair: LanguagePair, fetcher: @escaping TranslationDownloader.Fetch) async {
        _ = try? await TranslationDownloader.download(pair: pair, into: root, fetcher: fetcher)
    }

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    private actor Flag {
        private(set) var value = false
        func raise() { value = true }
    }
}
