import XCTest

@testable import MurmurKit

/// Model-backed cases skip without the weights; routing and gating never need
/// them.
final class TranslationServiceTests: XCTestCase {
    private let modelsRoot = URL(fileURLWithPath: "/Volumes/DATA/bergamot-arm64/models")

    private func service(residentLimit: Int = 2) throws -> TranslationService {
        guard FileManager.default.fileExists(
            atPath: modelsRoot.appendingPathComponent("moz-ruen").path)
        else { throw XCTSkip("translation models not installed") }
        return TranslationService(modelsRoot: modelsRoot, residentLimit: residentLimit)
    }

    // MARK: routing

    func test_identity_returns_the_input_untouched() async throws {
        let service = TranslationService(modelsRoot: modelsRoot)
        let text = "ничего не делать"
        let out = try await service.translate(text, from: "ru", to: "ru")
        XCTAssertEqual(out, text)
        // No model was needed, so none was loaded.
        let resident = await service.residentPairs
        XCTAssertTrue(resident.isEmpty)
    }

    func test_blank_input_costs_no_model_load() async throws {
        let service = TranslationService(modelsRoot: modelsRoot)
        let out = try await service.translate("  \n ", from: "ru", to: "en")
        XCTAssertEqual(out, "")
        let resident = await service.residentPairs
        XCTAssertTrue(resident.isEmpty)
    }

    func test_unsupported_pair_names_both_sides() async {
        let service = TranslationService(modelsRoot: modelsRoot)
        do {
            _ = try await service.translate("x", from: "ru", to: "mt")
            XCTFail("expected Unsupported")
        } catch let error as TranslationService.Unsupported {
            XCTAssertEqual(error.source, "ru")
            XCTAssertEqual(error.target, "mt")
        } catch {
            XCTFail("expected Unsupported, got \(error)")
        }
    }

    // MARK: execution

    func test_direct_route_translates() async throws {
        let service = try service()
        let out = try await service.translate(
            "Я пришлю документы завтра.", from: "ru", to: "en")
        print("  [direct] ru->en: \(out)")
        XCTAssertTrue(out.lowercased().contains("tomorrow"), out)
        let resident = await service.residentPairs
        XCTAssertEqual(resident.count, 1)
    }

    func test_pivot_route_runs_both_legs_and_keeps_both_resident() async throws {
        let service = try service()
        guard case .pivot = service.route(from: "fi", to: "de") else {
            return XCTFail("fi-de should pivot")
        }
        let out = try await service.translate(
            "Lähetän asiakirjat huomenna.", from: "fi", to: "de")
        print("  [pivot] fi->en->de: \(out)")
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.lowercased().contains("morgen"), out)
        let resident = await service.residentPairs
        XCTAssertEqual(Set(resident.map(\.description)), ["fi-en", "en-de"])
    }

    func test_a_failing_leg_is_named_and_stops_the_route() async throws {
        // en-xx does not exist, so the second leg of ru -> xx cannot load. The
        // failure must name that leg rather than the route as a whole.
        let service = TranslationService(modelsRoot: modelsRoot)
        do {
            _ = try await service.translate("привет", from: "ru", to: "zz")
            XCTFail("expected a failure")
        } catch let error as TranslationService.Unsupported {
            XCTAssertEqual(error.target, "zz")  // rejected before any load
        } catch {
            XCTFail("expected Unsupported, got \(error)")
        }
    }

    func test_cache_evicts_least_recently_used() async throws {
        let service = try service(residentLimit: 2)
        _ = try await service.translate("Привет.", from: "ru", to: "en")
        _ = try await service.translate("Hello.", from: "en", to: "de")
        _ = try await service.translate("Hei.", from: "fi", to: "en")
        let resident = await service.residentPairs.map(\.description)
        XCTAssertEqual(resident.count, 2)
        XCTAssertFalse(resident.contains("ru-en"), "oldest should have been evicted")
        XCTAssertTrue(resident.contains("fi-en"))
    }

    // MARK: the fast-loop gate

    func test_languages_with_an_unreliable_preview_lose_the_live_draft() {
        for language in ["ar", "ja", "ko", "zh", "vi"] {
            XCTAssertFalse(DictationMode.allowsLiveDraft(language: language), language)
            XCTAssertEqual(DictationMode.hybrid.effective(for: language), .accurate)
            XCTAssertEqual(DictationMode.fast.effective(for: language), .accurate)
            XCTAssertEqual(DictationMode.available(for: language), [.accurate])
        }
    }

    func test_region_qualified_codes_gate_the_same_as_their_base() {
        XCTAssertFalse(DictationMode.allowsLiveDraft(language: "zh-Hans"))
        XCTAssertFalse(DictationMode.allowsLiveDraft(language: "ja-JP"))
        XCTAssertEqual(DictationMode.hybrid.effective(for: "zh-Hant"), .accurate)
    }

    func test_other_languages_keep_every_mode() {
        for language in ["ru", "en", "de", "fi", "en-GB"] {
            XCTAssertTrue(DictationMode.allowsLiveDraft(language: language), language)
            XCTAssertEqual(DictationMode.hybrid.effective(for: language), .hybrid)
            XCTAssertEqual(DictationMode.available(for: language).count, 3)
        }
    }

    func test_automatic_detection_is_not_gated() {
        // The language is unknown until the model has already produced text, so
        // gating "auto" would disable the live draft for everyone.
        XCTAssertTrue(DictationMode.allowsLiveDraft(language: nil))
        XCTAssertEqual(DictationMode.hybrid.effective(for: nil), .hybrid)
    }
}
