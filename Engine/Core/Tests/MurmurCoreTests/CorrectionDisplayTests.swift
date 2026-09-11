import XCTest
@testable import MurmurCore

final class CorrectionDisplayTests: XCTestCase {
    func testDraftAppendsAreNotCorrections() {
        var display = CorrectionDisplay()
        display.update(.init(revision: 1, confirmed: [], provisional: "hello"))
        display.update(.init(revision: 2, confirmed: [], provisional: "hello world"))
        XCTAssertFalse(display.hasChanges)
        XCTAssertTrue(display.runs.allSatisfy { $0.tone == .draft })
    }
    func testCorrectionHighlightsOnlyReplacementAndKeepsNewDraftDim() {
        var display = CorrectionDisplay()
        display.update(.init(revision: 1, confirmed: [], provisional: "send the revenu slide"))
        display.update(.init(revision: 2, confirmed: [phrase("Send the revenue slide")], provisional: "tomorrow"))
        XCTAssertEqual(display.runs.filter { $0.tone == .changed }.map(\.text), ["Send", "revenue"])
        XCTAssertEqual(display.runs.last?.tone, .draft)
        XCTAssertEqual(display.text, "Send the revenue slide tomorrow")
    }
    func testDeletionDoesNotResurrectOldWordsAndPreservesWhitespace() {
        var display = CorrectionDisplay()
        display.update(.init(revision: 1, confirmed: [], provisional: "well well\nhello"))
        display.finish("well\nhello")
        XCTAssertEqual(display.runs.map(\.text).joined(), "well\nhello")
        XCTAssertFalse(display.hasChanges)
    }
    func testConfirmedTextWithoutDraftDoesNotFlashWholeParagraph() {
        var display = CorrectionDisplay()
        display.update(.init(revision: 1, confirmed: [phrase("Привет, мир!")], provisional: ""))
        XCTAssertFalse(display.hasChanges)
        XCTAssertEqual(display.runs.first?.tone, .confirmed)
    }
    func testStaleSnapshotsAndCallbacksAfterFinishCannotOverwriteFinalText() {
        var display = CorrectionDisplay()
        display.update(.init(revision: 3, confirmed: [], provisional: "draft"))
        XCTAssertFalse(display.update(.init(revision: 2, confirmed: [], provisional: "old")))
        display.finish("Final")
        XCTAssertFalse(display.update(.init(revision: 4, confirmed: [], provisional: "late")))
        XCTAssertEqual(display.text, "Final")
    }
    func testUnicodeAndRepeatedWordsKeepTextIntact() {
        var display = CorrectionDisplay()
        display.update(.init(revision: 1, confirmed: [], provisional: "да да привет 🌍"))
        display.finish("Да да привет 🌎")
        XCTAssertEqual(display.runs.filter { $0.tone == .changed }.map(\.text), ["Да", "🌎"])
        XCTAssertEqual(display.runs.map(\.text).joined(), display.text)
    }
    func testFinishPreservesCorrectionFlashWithoutHighlightingNewDraft() {
        var display = CorrectionDisplay()
        display.update(.init(revision: 1, confirmed: [], provisional: "send revenu"))
        display.update(.init(revision: 2, confirmed: [phrase("send revenue")], provisional: "tomorrow"))
        display.finish("send revenue tomorrow")
        XCTAssertEqual(display.runs.filter { $0.tone == .changed }.map(\.text), ["revenue"])
    }
    private func phrase(_ text: String) -> CaptionSegment {
        CaptionSegment(id: 1, startSample: 0, endSample: 16000, text: text, state: .confirmed)
    }
}
