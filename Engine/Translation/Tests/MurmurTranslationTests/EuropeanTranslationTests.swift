import XCTest
@testable import MurmurCore
@testable import MurmurTranslation

final class EuropeanTranslationTests: XCTestCase {
    func testEveryEULanguageHasPinnedQualityRoutesInBothDirections() throws {
        let eu: Set<String> = ["bg","cs","da","de","el","en","es","et","fi","fr","ga","hr","hu","it","lt","lv","mt","nl","pl","pt","ro","sk","sl","sv"]
        XCTAssertEqual(eu.count, 24)
        XCTAssertTrue(eu.isSubset(of: LanguagePair.qualityLanguages))
        let service = TranslationService(modelsRoot: URL(fileURLWithPath: "/nonexistent-murmur-catalog-test"))
        for from in LanguagePair.qualityLanguages {
            for to in LanguagePair.qualityLanguages where from != to {
                let route = try XCTUnwrap(service.qualityDownloadRoute(from: from, to: to))
                let legs: [LanguagePair]
                switch route { case .direct(let leg): legs = [leg]; case .pivot(let a, let b): legs = [a,b] }
                for leg in legs {
                    let files = try TranslationDownloader.artifacts(for: leg, kind: .quality)
                    XCTAssertTrue(files.contains { $0.localName == "model.bin" })
                    XCTAssertTrue(files.allSatisfy { $0.sha256.count == 64 && $0.downloadBytes > 0 })
                }
            }
        }
    }

    func testOPUSCatalogIsIndependentOfFastPreviewAndSpeechCatalogs() {
        XCTAssertNil(LanguagePair.route(from: "en", to: "ga"))
        XCTAssertNotNil(LanguagePair.qualityRoute(from: "en", to: "ga"))
        XCTAssertTrue(KeyboardConfiguration(source: "mt", target: "ga").isValid)
        XCTAssertFalse(KeyboardConfiguration(source: "ga", target: "en").isValid)
        XCTAssertTrue(SpeechModelChoice.parakeet.supports("mt"))
        XCTAssertFalse(SpeechModelChoice.parakeet.supports("ga"))
    }

    func testLanguagesOutsideParakeetUseWhisperAndTheirOwnTargetTags() throws {
        let tags = ["be": ">>bel<<", "bs": ">>bos_Latn<<", "ca": ">>cat<<", "is": ">>isl<<",
                    "mk": ">>mkd<<", "nb": ">>nob<<", "sr": ">>srp_Cyrl<<"]
        XCTAssertEqual(Set(tags.keys), SpeechModelChoice.whisperLanguages)
        let catalog = TranslationProfileCatalog.baseline
        for (language, tag) in tags {
            XCTAssertTrue(LanguagePair.qualityLanguages.contains(language), language)
            XCTAssertFalse(SpeechModelChoice.parakeet.supports(language), language)
            XCTAssertEqual(SpeechRecognitionProfile.baselineModel(language: language), .whisper, language)
            XCTAssertFalse(KeyboardConfiguration(source: language, target: "en").isValid, language)
            XCTAssertEqual(try XCTUnwrap(catalog.bindings[.init(source: "en", target: language)]).targetTag, tag)
            XCTAssertEqual(try XCTUnwrap(catalog.bindings[.init(source: language, target: "en")]).targetTag, "")
        }
        // Catalan into English is the Spanish checkpoint, so it downloads nothing new.
        XCTAssertEqual(catalog.bindings[.init(source: "ca", target: "en")]?.modelID,
                       catalog.bindings[.init(source: "es", target: "en")]?.modelID)
        XCTAssertEqual(SpeechModelChoice.whisperLanguageCode("nb"), "no")
        XCTAssertEqual(SpeechModelChoice.whisperLanguageCode("ca"), "ca")
        XCTAssertNil(SpeechModelChoice.whisperLanguageCode(nil))
    }

    func testArabicTranslatesWithItsOwnOPUSPacksButKeepsItsSpeechModel() throws {
        let catalog = TranslationProfileCatalog.baseline
        XCTAssertTrue(LanguagePair.qualityLanguages.contains("ar"))
        XCTAssertEqual(try XCTUnwrap(catalog.bindings[.init(source: "en", target: "ar")]).targetTag, ">>ara<<")
        XCTAssertEqual(try XCTUnwrap(catalog.bindings[.init(source: "ar", target: "en")]).targetTag, "")
        XCTAssertFalse(SpeechModelChoice.parakeet.supports("ar"))
        XCTAssertEqual(SpeechRecognitionProfile.baselineModel(language: "ar"), .cohereArabic)
        XCTAssertFalse(KeyboardConfiguration(source: "ar", target: "en").isValid)
        XCTAssertTrue(KeyboardConfiguration(source: "en", target: "ar").isValid)
    }

    func testEveryConvertedDirectionRunsThroughTheNativeSwiftEngine() async throws {
        guard let path = ProcessInfo.processInfo.environment["MURMUR_EU_NATIVE_ROOT"],
              let manifest = ProcessInfo.processInfo.environment["MURMUR_EU_SOURCES"] else { throw XCTSkip("Local converted OPUS packs required") }
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest))) as! [[String: Any]]
        let root = URL(fileURLWithPath: path)
        let service = TranslationService(modelsRoot: root)
        var outputs: [[String: Any]] = []
        for row in rows {
            let from = row["from"] as! String, to = row["to"] as! String, input = row["sample_input"] as! String
            let result = try await service.translateQuality(input, from: from, to: to)
            XCTAssertTrue(result.usedQuality)
            XCTAssertEqual(result.passes.count, 1)
            XCTAssertFalse(result.text.isEmpty)
            XCTAssertNotEqual(result.text, input)
            XCTAssertLessThan(result.text.count, 180, "Short source must not produce runaway repetition")
            outputs.append(["from": from, "to": to, "input": input, "output": result.text, "usedQuality": result.usedQuality])
            await service.evictAll()
            let retained = await service.residentModelCount
            XCTAssertEqual(retained, 0)
        }
        // Neither side has a Mozilla preview. Preparation and both output APIs
        // must still work entirely offline using the installed quality packs.
        let session = TranslationSession(modelsRoot: root)
        try await session.prepare(from: "mt", to: "ga")
        let preview = try await session.preview("Nibgħat id-dokumenti għada.", from: "mt", to: "ga")
        let final = try await session.finish("Nibgħat id-dokumenti għada.", from: "mt", to: "ga")
        XCTAssertFalse(preview.isEmpty); XCTAssertFalse(final.isEmpty)
        await session.unload()
        let remaining = await session.residentModelCount
        XCTAssertEqual(remaining, 0)
        outputs.append(["from": "mt", "to": "ga", "preview": preview, "output": final, "usedQuality": true])
        if let report = ProcessInfo.processInfo.environment["MURMUR_EU_NATIVE_REPORT"] {
            try JSONSerialization.data(withJSONObject: outputs, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: report))
        }
    }
}
