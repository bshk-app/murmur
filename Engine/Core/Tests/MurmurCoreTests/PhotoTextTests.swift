import XCTest
@testable import MurmurCore
final class PhotoTextTests: XCTestCase {
    private func line(_ text: String, x: Double = 0.1, y: Double, width: Double = 0.35) -> PhotoTextLine {
        .init(text: text, confidence: 0.9, bounds: CGRect(x: x, y: y, width: width, height: 0.04))
    }
    func testParagraphsDoNotCrossColumns() {
        let blocks = PhotoTextGrouping.blocks(from: [line("This is the left paragraph", y: 0.1), line("This is the right paragraph", x: 0.55, y: 0.1), line("continues left", y: 0.15), line("continues right", x: 0.55, y: 0.15)])
        XCTAssertEqual(blocks.map(\.source), ["This is the left paragraph continues left", "This is the right paragraph continues right"])
        XCTAssertEqual(blocks.map(\.lineCount), [2,2])
    }
    func testPricesAndOverlappingRowsStaySeparate() {
        let blocks = PhotoTextGrouping.blocks(from: [line("Coffee 3.50", y: 0.1), line("Tea 2.50", y: 0.15), line("Other column", x: 0.6, y: 0.15)])
        XCTAssertEqual(blocks.count, 3)
    }
    func testGeometryAndStableIdentitySurviveGrouping() {
        let first = line("A complete first line", y: 0.1), second = line("The next line", y: 0.15)
        let block = PhotoTextGrouping.blocks(from: [second, first])[0]
        XCTAssertEqual(block.id, first.id)
        XCTAssertEqual(block.bounds, first.bounds.union(second.bounds))
    }
    func testRTLOrderAndEmptyResults() {
        XCTAssertTrue(PhotoTextGrouping.blocks(from: []).isEmpty)
        let blocks = PhotoTextGrouping.blocks(from: [line("يسار", y: 0.1), line("يمين", x: 0.6, y: 0.1)], rightToLeft: true)
        XCTAssertEqual(blocks.map(\.source), ["يمين", "يسار"])
    }
    func testShortStatusLabelsAreNotMerged() {
        let blocks = PhotoTextGrouping.blocks(from: [line("Preparing", y: 0.1), line("Connecting", y: 0.15), line("Getting info", y: 0.2)])
        XCTAssertEqual(blocks.map(\.source), ["Preparing", "Connecting", "Getting info"])
    }
    func testPurePricesDoNotNeedMachineTranslation() {
        let blocks = PhotoTextGrouping.blocks(from: [line("€ 12.50", y: 0.1), line("Coffee", y: 0.2)])
        XCTAssertFalse(blocks[0].requiresTranslation)
        XCTAssertTrue(blocks[1].requiresTranslation)
    }
}
