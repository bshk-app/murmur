import XCTest
@testable import MurmurCore

final class OnboardingFeedbackTests: XCTestCase {
    func testSingleLanguagePreloadsDictationAndBothTranslationDirections() {
        let plan = OfflinePreloadPlan(languages: ["ru"])
        XCTAssertEqual(plan.speech, ["ru"])
        XCTAssertEqual(Set(plan.translations), [.init(source: "ru", target: "en"), .init(source: "en", target: "ru")])
    }
    func testMultipleLanguagesCoverAllDirectionsWithoutDuplicatePacks() {
        let plan = OfflinePreloadPlan(languages: ["fi", "ru"])
        XCTAssertEqual(plan.speech, ["fi", "ru"])
        XCTAssertEqual(plan.translations.count, 6)
        XCTAssertEqual(Set(plan.translations).count, 6)
        XCTAssertTrue(plan.translations.contains(.init(source: "fi", target: "ru")))
        XCTAssertTrue(plan.translations.contains(.init(source: "ru", target: "fi")))
    }
    func testSkippingPreloadDoesNotScheduleAnyDownloads() {
        let plan = OfflinePreloadPlan(languages: [])
        XCTAssertTrue(plan.speech.isEmpty); XCTAssertTrue(plan.translations.isEmpty)
    }
    func testSharingMatchesTheSelectedReadingMode() {
        let note = VoiceNote(text: "Original", translation: "Перевод", sourceLanguage: "en", targetLanguage: "ru", duration: 1, model: "test")
        XCTAssertEqual(NoteContent.original.text(in: note), "Original")
        XCTAssertEqual(NoteContent.translation.text(in: note), "Перевод")
    }
    func testUntranslatedNoteExportsOriginal() {
        let note = VoiceNote(text: "Original", sourceLanguage: "en", duration: 1, model: "test")
        XCTAssertEqual(NoteContent.translation.text(in: note), "Original")
    }
    @MainActor func testTranslationUsesSelectedTierAndInvalidatesOldOutput() async throws {
        let engine = QualitySpy()
        let controller = TextTranslationModel(engine: engine, source: "ru", target: "en", availableTargets: { _ in ["en", "da"] })
        controller.input = "Hello"
        controller.setQuality(.fast)
        await controller.start()?.value
        XCTAssertEqual(controller.output, "fast")
        controller.setQuality(.quality)
        XCTAssertEqual(controller.output, "")
        await controller.start()?.value
        XCTAssertEqual(controller.output, "quality")
        let used = await engine.prepared
        XCTAssertEqual(used, [.fast, .quality])
        controller.setQuality(.fast)
        controller.setTarget("da")
        XCTAssertEqual(controller.availableQualities, [.quality])
        XCTAssertEqual(controller.quality, .quality)
    }
}
private actor QualitySpy: TextTranslationEngine {
    private var quality = ProcessingQuality.quality
    var prepared: [ProcessingQuality] = []
    nonisolated func availableQualities(from: String, to: String) -> [ProcessingQuality] { ProcessingQuality.translationOptions(from: from, to: to) }
    func setQuality(_ value: ProcessingQuality) { quality = value }
    func prepare(from: String, to: String, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws { prepared.append(quality) }
    func translate(_ text: String, from: String, to: String) async throws -> String { quality.rawValue }
    var residentModelCount: Int { 0 }
    func unload() async {}
}
