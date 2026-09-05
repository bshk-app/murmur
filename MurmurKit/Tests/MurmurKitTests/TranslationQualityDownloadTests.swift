import XCTest
@testable import MurmurKit

/// The quality tier reuses the fast tier's download machinery through `Kind`.
/// These cover the places where the two genuinely differ, because that is
/// where a shared engine can quietly do the wrong thing for one of them.
final class TranslationQualityDownloadTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("murmur-quality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func pair(_ source: String, _ target: String) throws -> LanguagePair {
        try XCTUnwrap(LanguagePair(source: source, target: target))
    }

    // MARK: - shape

    /// The tag file is not cosmetic: `en-ru` is a group checkpoint and without
    /// it the model chooses a Slavic target on its own. `ru-en` has a single
    /// target and must not carry one, or the tag would be fed as a word.
    func testOnlyTheGroupCheckpointCarriesATargetTag() throws {
        let toEnglish = try TranslationDownloader.artifacts(
            for: pair("ru", "en"), kind: .quality).map(\.localName)
        let fromEnglish = try TranslationDownloader.artifacts(
            for: pair("en", "ru"), kind: .quality).map(\.localName)

        XCTAssertFalse(toEnglish.contains("target_tag.txt"),
                       "ru-en has one target and needs no tag: \(toEnglish)")
        XCTAssertTrue(fromEnglish.contains("target_tag.txt"),
                      "en-ru is eng->zle and picks a language from the tag: \(fromEnglish)")
    }

    /// Every quality file the engine loads must be pinned, exactly as for the
    /// fast tier. An unpinned one would be unverified bytes from a mirror.
    func testEveryQualityArtifactIsPinnedAndKeepsItsName() throws {
        for direction in [("ru", "en"), ("en", "ru")] {
            let items = try TranslationDownloader.artifacts(
                for: pair(direction.0, direction.1), kind: .quality)
            XCTAssertFalse(items.isEmpty)
            for item in items {
                XCTAssertEqual(item.sha256.count, 64,
                               "\(item.localName) is not pinned to a sha256")
                XCTAssertEqual(item.remoteName, item.localName,
                               "renaming \(item.remoteName) invents a mapping to get wrong")
                XCTAssertGreaterThan(item.downloadBytes, 0)
            }
        }
    }

    func testAnUnconvertedDirectionIsRefusedRatherThanFetchedUnchecked() throws {
        XCTAssertThrowsError(
            try TranslationDownloader.artifacts(for: pair("de", "en"), kind: .quality)
        ) { error in
            XCTAssertEqual(error as? TranslationDownloader.Err,
                           .unpinnedDirection("deen"))
        }
    }

    /// int8 weights barely compress, so this mirror serves them raw. If the
    /// suffix were ever set to .gz the fetch path would try to inflate a
    /// quarter-gigabyte of non-gzip and fail every download.
    func testTheQualityMirrorServesUncompressedBytes() {
        XCTAssertTrue(TranslationDownloader.Source.murmurQualityMirror
            .compressionSuffix.isEmpty)
    }

    func testSizeIsReportedPerKind() throws {
        let ruen = try pair("ru", "en")
        let fast = try XCTUnwrap(
            TranslationDownloader.expectedDownloadBytes(for: ruen, kind: .fast))
        let quality = try XCTUnwrap(
            TranslationDownloader.expectedDownloadBytes(for: ruen, kind: .quality))
        XCTAssertLessThan(fast, 30_000_000, "the fast tier is ~22 MB")
        XCTAssertGreaterThan(quality, 200_000_000, "the quality tier is ~253 MB")
    }

    // MARK: - installed-ness

    /// The two tiers install side by side. A quality model present must not
    /// make the fast one look installed, or the app would try to open bergamot
    /// weights that were never fetched.
    func testTiersAreInstalledIndependently() throws {
        let ruen = try pair("ru", "en")
        let directory = root.appendingPathComponent(ruen.qualityModelDirectoryName)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        for item in try TranslationDownloader.artifacts(for: ruen, kind: .quality) {
            try Data("x".utf8).write(
                to: directory.appendingPathComponent(item.localName))
        }

        XCTAssertTrue(TranslationDownloader.isInstalled(pair: ruen, in: root,
                                                        kind: .quality))
        XCTAssertFalse(TranslationDownloader.isInstalled(pair: ruen, in: root,
                                                         kind: .fast),
                       "a quality install must not satisfy the fast tier")
    }

    /// The fast tier's sentinel is the config it generates last; the quality
    /// tier has no generated file, so its sentinel is the weights. A directory
    /// holding everything *except* the weights is not an installation.
    func testAQualityDirectoryWithoutWeightsIsNotInstalled() throws {
        let ruen = try pair("ru", "en")
        let directory = root.appendingPathComponent(ruen.qualityModelDirectoryName)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        for item in try TranslationDownloader.artifacts(for: ruen, kind: .quality)
        where item.localName != "model.bin" {
            try Data("x".utf8).write(
                to: directory.appendingPathComponent(item.localName))
        }
        XCTAssertFalse(TranslationDownloader.isInstalled(pair: ruen, in: root,
                                                         kind: .quality))
    }

    // MARK: - space

    /// 200 MB clears the old fixed 128 MiB bar and is nowhere near enough for a
    /// 253 MB model. Before the requirement was derived from the queued files,
    /// this started the download and failed partway through.
    func testADiskTooSmallForAQualityModelIsRefusedUpFront() async throws {
        let ruen = try pair("ru", "en")
        var fetched = false
        do {
            _ = try await TranslationDownloader.download(
                pair: ruen, into: root, kind: .quality,
                fetcher: { _, _ in
                    fetched = true
                    return Data()
                },
                freeSpace: { _ in 200 * 1_000_000 })
            XCTFail("expected the download to be refused")
        } catch let error as TranslationDownloader.Err {
            guard case let .insufficientSpace(needed, available) = error else {
                return XCTFail("expected insufficientSpace, got \(error)")
            }
            XCTAssertGreaterThan(needed, available)
            XCTAssertGreaterThan(needed, 250_000_000,
                                 "the requirement must reflect the 253 MB model")
        }
        XCTAssertFalse(fetched, "refusal must come before any bytes move")
    }

    /// The same disk is ample for a fast model, so the stricter requirement
    /// must not have become a blanket refusal.
    func testTheSameDiskStillAllowsAFastModel() throws {
        let ruen = try pair("ru", "en")
        let items = try TranslationDownloader.artifacts(for: ruen, kind: .fast)
        let needed = TranslationDownloader.spaceNeeded(for: items, kind: .fast)
        XCTAssertLessThan(needed, 200 * 1_000_000)
        // Gzip is what travels; the inflated file is what has to fit.
        let transferred = items.reduce(0) { $0 + $1.downloadBytes }
        XCTAssertGreaterThan(needed, Int64(transferred),
                             "compressed size is not install size")
    }

    // MARK: - serialized writes

    /// A second quality download must be refused *because a slot is busy*,
    /// not because of a space computation that double-counts the first
    /// download's already-written bytes against its own full original claim.
    /// Proven by making the refusal arrive while the first is demonstrably
    /// still writing (blocked on a gate this test controls), and confirming
    /// the error is the dedicated `qualityDownloadBusy` case, not
    /// `insufficientSpace`.
    func testASecondQualityDownloadIsRefusedWhileTheFirstIsWriting() async throws {
        let ruen = try pair("ru", "en")
        let enru = try pair("en", "ru")
        let started = Gate()
        let release = Gate()

        let blockingFetcher: TranslationDownloader.Fetch = { _, _ in
            await started.open()
            await release.wait()
            throw CancellationError()
        }

        let first = Task {
            try? await TranslationDownloader.download(
                pair: ruen, into: root, kind: .quality, fetcher: blockingFetcher)
        }
        await started.wait()   // ru-en's write phase has begun and is now blocked

        do {
            _ = try await TranslationDownloader.download(
                pair: enru, into: root, kind: .quality, fetcher: { _, _ in Data() })
            XCTFail("expected qualityDownloadBusy while ru-en is still writing")
        } catch let error as TranslationDownloader.Err {
            XCTAssertEqual(error, .qualityDownloadBusy)
        }

        await release.open()
        _ = await first.value
    }

    /// The slot is released once the first download finishes (successfully or
    /// not), so a second pair is not permanently locked out by an earlier
    /// one's failure.
    func testTheSlotIsFreedAfterTheFirstDownloadFinishes() async throws {
        let ruen = try pair("ru", "en")
        let enru = try pair("en", "ru")

        // Fails fast on the fake bytes - the point is only that it releases.
        _ = try? await TranslationDownloader.download(
            pair: ruen, into: root, kind: .quality, fetcher: { _, _ in Data() })

        do {
            _ = try await TranslationDownloader.download(
                pair: enru, into: root, kind: .quality, fetcher: { _, _ in Data() })
            XCTFail("expected a digest failure on fake bytes, not success")
        } catch let error as TranslationDownloader.Err {
            XCTAssertNotEqual(error, .qualityDownloadBusy,
                              "the slot should have been released when ru-en finished")
    }
    }

    // MARK: - the real thing

    /// Downloads 253 MB from the live mirror, verifies every digest, and
    /// translates with what landed. Gated because of the size, but it is the
    /// only test that proves the published bytes, the pinned digests, the
    /// uncompressed path and the engine agree with each other.
    func testEndToEndQualityDownloadAndTranslate() async throws {
        guard ProcessInfo.processInfo.environment["MURMUR_NETWORK_TESTS"] == "1"
        else { throw XCTSkip("set MURMUR_NETWORK_TESTS=1") }

        let ruen = try pair("ru", "en")
        let directory = try await TranslationDownloader.download(
            pair: ruen, into: root, kind: .quality)

        XCTAssertTrue(TranslationDownloader.isInstalled(pair: ruen, in: root,
                                                        kind: .quality))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("config.bergamot.yml").path),
            "the quality tier downloads config.json; nothing should synthesise a bergamot config")

        let translator = try QualityTranslator(pair: ruen, modelsRoot: root)
        let out = try translator.translate("Можем ли мы перенести встречу на четверг?")
        XCTAssertTrue(out.lowercased().contains("thursday"), out)
    }
}

/// A one-shot open gate: `wait()` suspends until `open()` is called, or
/// returns immediately if it already was. Used to drive a fake fetcher to a
/// specific, controlled point in its lifecycle instead of guessing with a
/// sleep.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
