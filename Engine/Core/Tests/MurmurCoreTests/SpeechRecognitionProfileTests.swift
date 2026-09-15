import XCTest
@testable import MurmurCore

final class SpeechRecognitionProfileTests: XCTestCase {
    func testLegacyRecommendationRemainsAutomaticButExplicitChoiceSurvives() {
        XCTAssertFalse(SpeechRecognitionProfile.selectionIsExplicit(savedFlag: nil, savedModel: .parakeet, language: "fi"))
        XCTAssertTrue(SpeechRecognitionProfile.selectionIsExplicit(savedFlag: nil, savedModel: .whisper, language: "fi"))
        XCTAssertTrue(SpeechRecognitionProfile.selectionIsExplicit(savedFlag: true, savedModel: .parakeet, language: "fi"))
        XCTAssertFalse(SpeechRecognitionProfile.selectionIsExplicit(savedFlag: false, savedModel: .whisper, language: "fi"))
    }
    private let evidence = String(repeating: "a", count: 64)
    func testBaselineAndLiveStages() throws {
        for language in ["ru", "en", "fi", "de", "fr"] {
            let p = try SpeechRecognitionProfile.resolve(language: language, mode: .hybrid)
            XCTAssertEqual(p.model, language == "ru" ? .gigaam : .parakeet)
            XCTAssertNotNil(p.previewStage)
            XCTAssertEqual(p.origin, .baseline)
        }
        let arabic = try SpeechRecognitionProfile.resolve(language: "ar", mode: .hybrid)
        XCTAssertEqual(arabic.mode, .accurate)
        XCTAssertNil(arabic.previewStage)
        XCTAssertEqual(arabic.model, .cohereArabic)
    }
    func testOverrideRequiresSwitchEvidenceDeviceAndUniqueEntry() throws {
        let entry = QualifiedSpeechOverride(language: "fi", model: .whisper, evidenceSHA256: evidence, device: "iPhone16,1")
        XCTAssertEqual(try SpeechRecognitionProfile.resolve(language: "fi", mode: .hybrid, qualifiedOverrides: [entry]).model, .parakeet)
        let accepted = try SpeechRecognitionProfile.resolve(language: "fi", mode: .hybrid, qualifiedOverrides: [entry], enableQualifiedOverrides: true, device: "iPhone16,1")
        XCTAssertEqual(accepted.origin, .qualifiedOverride)
        XCTAssertEqual(accepted.model, .whisper)
        XCTAssertTrue(accepted.independentCorrector)
        for entries in [[entry, entry], [QualifiedSpeechOverride(language: "fi", model: .whisper, evidenceSHA256: "", device: "iPhone16,1")]] {
            XCTAssertEqual(try SpeechRecognitionProfile.resolve(language: "fi", mode: .hybrid, qualifiedOverrides: entries, enableQualifiedOverrides: true).origin, .baseline)
        }
        XCTAssertEqual(try SpeechRecognitionProfile.resolve(language: "fi", mode: .hybrid, qualifiedOverrides: [entry], enableQualifiedOverrides: true, device: "Mac").origin, .baseline)
        XCTAssertEqual(try SpeechRecognitionProfile.resolve(language: "fi", mode: .hybrid, explicitChoice: .parakeet, qualifiedOverrides: [entry], enableQualifiedOverrides: true).origin, .explicitChoice)
    }
    func testUnavailableAndUnsupportedCandidates() throws {
        XCTAssertThrowsError(try SpeechRecognitionProfile.candidate(language: "de", mode: .hybrid, runtimeID: "canary"))
        XCTAssertThrowsError(try SpeechRecognitionProfile.candidate(language: "fi", mode: .hybrid, runtimeID: "gigaam"))
        let candidate = try SpeechRecognitionProfile.candidate(language: "de", mode: .fast, runtimeID: "whisper")
        XCTAssertEqual(candidate.origin, .experimentalCandidate)
        XCTAssertNil(candidate.finalStage)
        XCTAssertNil(candidate.evidenceSHA256)
    }

    func testUnsupportedChosenModelFallsBackToTheLanguageBaseline() {
        for language in SpeechModelChoice.whisperLanguages {
            XCTAssertEqual(SpeechRecognitionProfile.model(.parakeet, for: language), .whisper, language)
        }
        XCTAssertEqual(SpeechRecognitionProfile.model(.parakeet, for: "ar"), .cohereArabic)
        XCTAssertEqual(SpeechRecognitionProfile.model(.whisper, for: "de"), .whisper)
        XCTAssertEqual(SpeechRecognitionProfile.model(.parakeet, for: "de"), .parakeet)
    }
}
