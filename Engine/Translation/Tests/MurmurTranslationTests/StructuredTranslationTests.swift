import XCTest
@testable import MurmurTranslation

final class StructuredTranslationTests: XCTestCase {
    func testFramingAndSentenceContext() {
        var calls: [String] = []
        let source = "  1. Hello  \r\n\r\n\t- [x] Visit https://example.org now.\n"
        let result = StructuredTranslation.translate(source) { calls.append($0); return $0.uppercased() }
        XCTAssertEqual(calls, ["Hello", "Visit https://example.org now."])
        XCTAssertEqual(result, "  1. HELLO  \r\n\r\n\t- [x] VISIT HTTPS://EXAMPLE.ORG NOW.\n")
    }
    func testLiteralLinesAndCodeFenceBypassModel() {
        let source = "https://example.org\nme@example.org\n```swift\nlet value = 1\n```\n123.45\n`literal`\n"
        XCTAssertEqual(StructuredTranslation.translate(source) { _ in XCTFail("Literal reached model"); return "" }, source)
    }
    func testEmptyAndWhitespace() {
        for source in ["", " \t\r\n\n", "\r", "\n"] {
            XCTAssertEqual(StructuredTranslation.translate(source) { _ in XCTFail(); return "" }, source)
        }
    }
    func testPropagatesTranslationFailure() {
        enum Failure: Error { case failed }
        XCTAssertThrowsError(try StructuredTranslation.translate("- hello") { _ in throw Failure.failed })
    }
}
