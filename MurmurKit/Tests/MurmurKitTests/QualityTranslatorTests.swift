import XCTest
@testable import MurmurKit

/// Exercises the CTranslate2 engine against a real model.
///
/// Skipped unless `MURMUR_CT2_MODEL` points at a directory holding a converted
/// ru->en model, because the weights are 253 MB and do not belong in the
/// repository. Run with:
///
///     MURMUR_CT2_MODEL=/Volumes/DATA/bergamot-arm64/models \
///       swift test --filter QualityTranslatorTests
final class QualityTranslatorTests: XCTestCase {
    private func translator() throws -> QualityTranslator {
        guard let root = ProcessInfo.processInfo.environment["MURMUR_CT2_MODEL"]
        else {
            throw XCTSkip("set MURMUR_CT2_MODEL to a directory of CT2 models")
        }
        let pair = LanguagePair(source: "ru", target: "en")
        return try QualityTranslator(pair: pair,
                                     modelsRoot: URL(fileURLWithPath: root))
    }

    func testTranslatesOneSentence() throws {
        let out = try translator().translate("Можем ли мы перенести встречу на четверг?")
        XCTAssertTrue(out.lowercased().contains("thursday"),
                      "expected the weekday to survive, got \(out)")
    }

    /// The load-bearing test. opus-mt is a sentence-level model and
    /// CTranslate2 does no splitting of its own, so an unsplit paragraph comes
    /// back as one capped hypothesis: measured before the fix, 4514 characters
    /// of Russian returned 360 characters that trailed into a repeating loop.
    /// That failure is silent - a successful call with most of the input gone -
    /// so this asserts on the tail rather than on the absence of an error.
    func testLongDictationIsNotSilentlyTruncated() throws {
        let sentences = (1...20).map {
            "Сегодня в городе номер \($0) открыли новую библиотеку."
        }
        let input = sentences.joined(separator: " ")
        let out = try translator().translate(input)

        // The last sentence must be present. A capped single hypothesis stops
        // long before it.
        XCTAssertTrue(out.contains("20"),
                      "the end of the input is missing, output was \(out.count) chars: \(out)")
        // And the whole thing must be of a plausible length, not a fragment.
        XCTAssertGreaterThan(out.count, input.count / 2,
                             "output collapsed to \(out.count) chars from \(input.count)")
    }

    func testLineStructureSurvives() throws {
        let input = "Первая строка тут.\nВторая строка отдельно."
        let out = try translator().translate(input)
        XCTAssertEqual(out.filter { $0 == "\n" }.count, 1,
                       "line breaks are the user's, not the model's: \(out)")
    }

    func testBlankInputIsNotAnError() throws {
        // Resolved outside the assertion: XCTAssertEqual takes an autoclosure,
        // and an XCTSkip thrown inside one is reported as a failure instead of
        // skipping the test.
        let engine = try translator()
        XCTAssertEqual(try engine.translate("   "), "")
    }

    func testMissingModelReportsUnavailableRatherThanCrashing() throws {
        let pair = LanguagePair(source: "xx", target: "yy")
        XCTAssertThrowsError(
            try QualityTranslator(pair: pair,
                                  modelsRoot: URL(fileURLWithPath: "/nonexistent"))
        ) { error in
            guard case QualityTranslator.Failure.modelUnavailable = error else {
                return XCTFail("expected modelUnavailable, got \(error)")
            }
        }
    }
}
