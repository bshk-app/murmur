import AppKit
import XCTest
@testable import Murmur

/// The draft drawn at the caret: where its lines go, which words make it on
/// screen, and in what type.
final class GhostTextTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// Every character, the space included, 10pt wide.
    private let measure: (String) -> CGFloat = { CGFloat($0.count) * 10 }
    private let marker: CGFloat = 24

    private func caret(x: CGFloat, y: CGFloat = 500) -> CGRect {
        CGRect(x: x, y: y, width: 0, height: 20)
    }

    private func words(_ s: String, confirmed: Bool = true) -> [GhostWord] {
        GhostWord.words(confirmed: confirmed ? s : "", partial: confirmed ? "" : s)
    }

    // MARK: geometry

    func testTheFirstLineStartsAtTheCaretAndWrapsInsideTheField() {
        let field = CGRect(x: 100, y: 400, width: 600, height: 200)
        let g = GhostText.geometry(caret: caret(x: 300), field: field, lineHeight: 20, visible: screen)
        XCTAssertEqual(g.baseY, 500)
        XCTAssertEqual(g.leftEdge, 100 + GhostText.padding, "the field's padding, guessed")
        XCTAssertEqual(g.rightEdge, 700 - GhostText.padding)
        XCTAssertEqual(g.maxLines, GhostText.maxLines)
        XCTAssertEqual(g.region.maxY, 520)
        XCTAssertEqual(g.region.minY, 500 - 2 * 20)
    }

    /// An empty field: the caret is where its lines start.
    func testACaretAtTheFieldsStartIsWhereItsLinesStart() {
        let field = CGRect(x: 100, y: 400, width: 600, height: 200)
        let g = GhostText.geometry(caret: caret(x: 112), field: field, lineHeight: 20, visible: screen)
        XCTAssertEqual(g.leftEdge, 112)
    }

    func testAFieldThatDoesNotSayGetsAFixedLineFromTheCaret() {
        let g = GhostText.geometry(caret: caret(x: 300), field: nil, lineHeight: 20, visible: screen)
        XCTAssertEqual(g.leftEdge, 300)
        XCTAssertEqual(g.rightEdge, 300 + GhostText.fallbackWidth)
    }

    /// Lines never run off the screen; a caret at its right edge wraps
    /// leftwards rather than into a sliver.
    func testLinesStayOnScreen() {
        let g = GhostText.geometry(caret: caret(x: 1400), field: nil, lineHeight: 20, visible: screen)
        XCTAssertEqual(g.rightEdge, 1440 - GhostText.padding)
        XCTAssertEqual(g.rightEdge - g.leftEdge, GhostText.minLineWidth)
        XCTAssertLessThanOrEqual(g.region.maxX, 1440)
    }

    /// A composer at the bottom of the screen has no room below its line.
    func testOnlyAsManyLinesAsFitBelowTheCaret() {
        let g = GhostText.geometry(caret: caret(x: 300, y: 25), field: nil, lineHeight: 20, visible: screen)
        XCTAssertEqual(g.maxLines, 2)
        let h = GhostText.geometry(caret: caret(x: 300, y: 5), field: nil, lineHeight: 20, visible: screen)
        XCTAssertEqual(h.maxLines, 1)
        XCTAssertGreaterThanOrEqual(h.region.minY, 0)
    }

    /// A search box, Spotlight: one line, whatever is below it.
    func testASingleLineFieldGetsOneLine() {
        let field = CGRect(x: 100, y: 490, width: 400, height: 30)
        let g = GhostText.geometry(caret: caret(x: 300), field: field, singleLine: true, lineHeight: 20,
                                   visible: screen)
        XCTAssertEqual(g.maxLines, 1)
        XCTAssertEqual(g.region.minY, 500)
        XCTAssertEqual(g.rightEdge, 500 - GhostText.padding)
        let all = (1 ... 40).map { "w\($0)" }
        let lines = GhostText.lines(words(all.joined(separator: " ")), elided: false, in: g,
                                    marker: marker, measure: measure)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].origin, CGPoint(x: 300, y: 500))
        XCTAssertTrue(lines[0].elided)
        XCTAssertEqual(lines[0].words.last?.text, "w40")
        XCTAssertLessThanOrEqual(lines[0].width, g.rightEdge - 300)
    }

    /// Its caret at the end of a long line: the draft gets the room the
    /// field would scroll to make, past its edge, not a sliver.
    func testASingleLineEndingAtTheCaretGetsRoom() {
        let field = CGRect(x: 100, y: 490, width: 400, height: 30)
        let g = GhostText.geometry(caret: caret(x: 490), field: field, singleLine: true, lineHeight: 20,
                                   visible: screen)
        XCTAssertEqual(g.rightEdge, 490 + GhostText.minLineWidth)
        let lines = GhostText.lines(words("hello there"), elided: false, in: g, marker: marker, measure: measure)
        XCTAssertEqual(lines.map(\.origin), [CGPoint(x: 490, y: 500)])
        XCTAssertEqual(lines[0].words.map(\.text), ["hello", "there"])
    }

    /// A long word in a short field: it keeps its line, cut from the left,
    /// rather than giving way to a bare ellipsis.
    func testTheNewestWordNeverDisappears() {
        let field = CGRect(x: 100, y: 490, width: 400, height: 30)
        let g = GhostText.geometry(caret: caret(x: 300), field: field, singleLine: true, lineHeight: 20,
                                   visible: screen)                         // 196pt after the caret
        let long = String(repeating: "x", count: 17)                         // 170pt + gap + marker = 199
        for text in [long, "short \(long)"] {
            let lines = GhostText.lines(words(text), elided: false, in: g, marker: marker, measure: measure)
            XCTAssertEqual(lines.count, 1)
            XCTAssertEqual(lines[0].words.map(\.text), [long])
            XCTAssertEqual(lines[0].elided, text != long)
            XCTAssertEqual(lines[0].width, 196)
            XCTAssertEqual(lines[0].clip, 196 - GhostText.markerGap - marker)
        }
        let fits = GhostText.lines(words("short"), elided: false, in: g, marker: marker, measure: measure)
        XCTAssertNil(fits[0].clip)
    }

    /// A chat composer is one line tall until you type: it is a text area,
    /// and grows, so its draft wraps.
    func testAShortTextAreaStillWraps() {
        let composer = CGRect(x: 100, y: 490, width: 600, height: 30)
        let g = GhostText.geometry(caret: caret(x: 108), field: composer, lineHeight: 20, visible: screen)
        XCTAssertEqual(g.maxLines, GhostText.maxLines)
    }

    // MARK: lines

    private var wide: GhostGeometry {
        GhostText.geometry(caret: caret(x: 300), field: CGRect(x: 100, y: 400, width: 600, height: 200),
                           lineHeight: 20, visible: screen)
    }

    func testShortTextSitsOnTheCaretsLineWithTheMarkerAfterIt() {
        let lines = GhostText.lines(words("hello world"), elided: false, in: wide, marker: marker, measure: measure)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].origin, CGPoint(x: 300, y: 500))
        XCTAssertEqual(lines[0].words.map(\.text), ["hello", "world"])
        XCTAssertTrue(lines[0].hasMarker)
        XCTAssertFalse(lines[0].elided)
        XCTAssertEqual(lines[0].width, 110 + GhostText.markerGap + marker)
    }

    /// Nothing heard yet: just the marker, on the caret.
    func testNoWordsIsJustTheMarker() {
        let lines = GhostText.lines([], elided: false, in: wide, marker: marker, measure: measure)
        XCTAssertEqual(lines, [GhostLine(origin: CGPoint(x: 300, y: 500), words: [], elided: false,
                                         hasMarker: true, width: marker)])
    }

    /// Like typed text: what does not fit after the caret continues at the
    /// field's left edge, one line down.
    func testLongerTextWrapsToTheFieldsLeftEdge() {
        // 396pt after the caret holds 39 characters; the rest wraps.
        let text = Array(repeating: "word", count: 10).joined(separator: " ")    // 49 characters
        let lines = GhostText.lines(words(text), elided: false, in: wide, marker: marker, measure: measure)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].words.count, 8)          // 8 × 4 + 7 spaces = 39 characters
        XCTAssertEqual(lines[1].origin, CGPoint(x: wide.leftEdge, y: 480))
        XCTAssertEqual(lines[1].words.count, 2)
        XCTAssertFalse(lines[0].hasMarker)
        XCTAssertTrue(lines[1].hasMarker)
        for line in lines {
            let room = (line.origin.x == 300 ? wide.rightEdge - 300 : wide.rightEdge - wide.leftEdge)
            XCTAssertLessThanOrEqual(line.width, room)
        }
    }

    /// Past three lines the oldest words give way to an ellipsis, so the
    /// newest are always on screen.
    func testTheNewestWordsStayOnScreen() {
        let all = (1 ... 60).map { "w\($0)" }
        let lines = GhostText.lines(words(all.joined(separator: " ")), elided: false, in: wide,
                                    marker: marker, measure: measure)
        XCTAssertEqual(lines.count, GhostText.maxLines)
        XCTAssertTrue(lines[0].elided)
        XCTAssertEqual(lines.last?.words.last?.text, "w60")
        let shown = lines.flatMap(\.words).map(\.text)
        XCTAssertEqual(shown, Array(all.suffix(shown.count)), "a contiguous tail")
    }

    /// The HUD already dropped the oldest words: the ellipsis says so.
    func testTextTheHUDTruncatedLeadsWithAnEllipsis() {
        let lines = GhostText.lines(words("the end"), elided: true, in: wide, marker: marker, measure: measure)
        XCTAssertTrue(lines[0].elided)
        XCTAssertEqual(lines[0].width, 10 + 10 + 70 + GhostText.markerGap + marker)
    }

    func testConfirmedAndPendingWordsKeepTheirTier() {
        let w = GhostWord.words(confirmed: "said this", partial: "maybe that")
        XCTAssertEqual(w.map(\.confirmed), [true, true, false, false])
        let lines = GhostText.lines(w, elided: false, in: wide, marker: marker, measure: measure)
        XCTAssertEqual(lines[0].words, w)
    }

    /// The caret at the end of a full line: the first word goes to the next one.
    func testACaretAtTheLinesEndStartsOnTheNextLine() {
        let field = CGRect(x: 100, y: 400, width: 600, height: 200)
        let g = GhostText.geometry(caret: caret(x: 690), field: field, lineHeight: 20, visible: screen)
        let lines = GhostText.lines(words("hello"), elided: false, in: g, marker: marker, measure: measure)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].origin, CGPoint(x: g.leftEdge, y: 480))
    }

    func testOneLineLeftShowsTheTailOnTheCaretsLine() {
        let g = GhostText.geometry(caret: caret(x: 300, y: 5), field: nil, lineHeight: 20, visible: screen)
        let all = (1 ... 80).map { "w\($0)" }
        let lines = GhostText.lines(words(all.joined(separator: " ")), elided: false, in: g,
                                    marker: marker, measure: measure)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].origin.x, 300)
        XCTAssertTrue(lines[0].elided)
        XCTAssertEqual(lines[0].words.last?.text, "w80")
        XCTAssertLessThanOrEqual(lines[0].width, g.rightEdge - 300)
    }

    /// A word longer than the line still shows, on a line of its own.
    func testAnOverlongWordGetsALineOfItsOwn() {
        let long = String(repeating: "x", count: 70)
        let lines = GhostText.lines(words("a \(long) b"), elided: false, in: wide, marker: marker, measure: measure)
        XCTAssertEqual(lines.map { $0.words.map(\.text) }, [["a"], [long], ["b"]])
    }

    // MARK: type

    func testTheFieldsFontWhenItsSizeAgreesWithTheLine() {
        let font = GhostText.font(for: FieldFont(name: "Helvetica", size: 13), caretHeight: 16)
        XCTAssertEqual(font.pointSize, 13)
        XCTAssertEqual(font.fontName, "Helvetica")
    }

    /// A page zoomed to 200% says 13px and draws 26pt.
    func testAZoomedPageIsSizedFromItsLine() {
        let font = GhostText.font(for: FieldFont(name: "Helvetica", size: 13), caretHeight: 32)
        XCTAssertEqual(font.pointSize, 25)
        XCTAssertEqual(font.familyName, "Helvetica")
    }

    func testNoAnswerIsSizedFromTheLine() {
        XCTAssertEqual(GhostText.font(for: nil, caretHeight: 21).pointSize, 16)
        XCTAssertEqual(GhostText.font(for: nil, caretHeight: 4).pointSize, 10)
        XCTAssertEqual(GhostText.font(for: FieldFont(name: "NoSuchFont", size: 14), caretHeight: 18).pointSize, 14)
    }

    /// The line pitch is the caret's height, within reason: a caret as tall
    /// as the field is not a line.
    func testTheLineHeightComesFromTheCaret() {
        let font = NSFont.systemFont(ofSize: 13)
        let natural = GhostText.naturalLineHeight(font)
        XCTAssertEqual(GhostText.lineHeight(caret: 23, font: font), 23)
        XCTAssertEqual(GhostText.lineHeight(caret: 8, font: font), natural)
        XCTAssertEqual(GhostText.lineHeight(caret: 200, font: font), natural * 2)
    }
}
