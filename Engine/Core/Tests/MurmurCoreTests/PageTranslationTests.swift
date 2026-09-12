import XCTest
@testable import MurmurCore

private actor PageEngine: TextTranslationEngine {
    let preserveMarkers: Bool
    let emptyInputs: Set<String>
    var calls: [String] = []
    var didUnload = false
    var cancelOnTranslate = false
    init(preserveMarkers: Bool = true, emptyInputs: Set<String> = []) { self.preserveMarkers = preserveMarkers; self.emptyInputs = emptyInputs }
    func prepare(from: String, to: String, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws { await onProgress(1) }
    func translate(_ text: String, from: String, to: String) async throws -> String {
        calls.append(text)
        if cancelOnTranslate { throw CancellationError() }
        if emptyInputs.contains(text) { return "" }
        return text.contains("__MM") && !preserveMarkers ? "broken markers" : text.replacingOccurrences(of: "Hello", with: "Hei").replacingOccurrences(of: "world", with: "maailma")
    }
    func setCancelled() { cancelOnTranslate = true }
    var residentModelCount: Int { didUnload ? 0 : 1 }
    func unload() async { didUnload = true }
}
final class PageTranslationTests: XCTestCase {
    func testInvisibleBOMInMixedDOMGroupDoesNotAbortPage() async throws {
        let engine = PageEngine(preserveMarkers: false, emptyInputs: ["\u{FEFF}"])
        let output = try await PageTranslationProcessor.translate(page([.init(id: "a", text: "Hello"), .init(id: "bom", text: "\u{FEFF}"), .init(id: "b", text: "world")]), from: "en", to: "fi", engine: engine) { _ in }
        XCTAssertEqual(output.translations.map(\.text), ["Hei", "\u{FEFF}", "maailma"])
    }
    func testStructuralSeparatorsNeverGoThroughTranslation() async throws {
        let engine = PageEngine(preserveMarkers: false, emptyInputs: ["/", ".", "123", "\u{200B}"])
        let runs = [PageTextRun(id: "a", text: "Hello"), .init(id: "slash", text: " / "), .init(id: "dot", text: "."), .init(id: "number", text: "123"), .init(id: "format", text: "\u{200B}"), .init(id: "b", text: "world")]
        let output = try await PageTranslationProcessor.translate(page(runs), from: "en", to: "fi", engine: engine) { _ in }
        XCTAssertEqual(output.translations.map(\.text), ["Hei", " / ", ".", "123", "\u{200B}", "maailma"])
        let calls = await engine.calls
        XCTAssertFalse(calls.contains { ["/", ".", "123", "\u{200B}"].contains($0) })
    }
    func testSeparatorOnlyLinesArePreservedInsideTextRun() async throws {
        let engine = PageEngine(emptyInputs: ["/"])
        let output = try await PageTranslationProcessor.translate(page([.init(id: "a", text: "Hello\n/\nworld")]), from: "en", to: "fi", engine: engine) { _ in }
        XCTAssertEqual(output.translations[0].text, "Hei\n/\nmaailma")
    }
    func testEmptyTranslationOfActualWordsStillFailsAndUnloads() async {
        let engine = PageEngine(emptyInputs: ["Hello"])
        do {
            _ = try await PageTranslationProcessor.translate(page([.init(id: "a", text: "Hello")]), from: "en", to: "fi", engine: engine) { _ in }
            XCTFail("Empty meaningful translation must not be silently accepted")
        } catch PageTranslationError.emptyTranslation {} catch { XCTFail("Unexpected error: \(error)") }
        let unloaded = await engine.didUnload; XCTAssertTrue(unloaded)
    }
    private func page(_ runs: [PageTextRun]) -> PageTranslationRequest { .init(runId: "test", groups: [.init(id: "g", runs: runs)], totalCharacters: runs.reduce(0) { $0 + $1.text.utf16.count }) }
    func testInlineGroupingAndWhitespaceReturnEveryRun() async throws {
        let engine = PageEngine()
        let output = try await PageTranslationProcessor.translate(page([.init(id:"a",text:"Hello "),.init(id:"space",text:" "),.init(id:"b",text:"world")]), from:"en",to:"fi",engine:engine) { _ in }
        XCTAssertEqual(output.translations,[.init(id:"a",text:"Hei "),.init(id:"space",text:" "),.init(id:"b",text:"maailma")])
        XCTAssertEqual(output.fallbackGroups,0)
        let calls = await engine.calls; XCTAssertEqual(calls.count,1)
        let unloaded = await engine.didUnload; XCTAssertTrue(unloaded)
    }
func testIndentationTrailingWhitespaceAndCRLFPreserved() async throws {
    let engine = PageEngine()
    let source = "  Hello  \r\n\r\n\tworld\n"
    let output = try await PageTranslationProcessor.translate(page([.init(id: "a", text: source)]), from: "en", to: "fi", engine: engine) { _ in }
    XCTAssertEqual(output.translations[0].text, "  Hei  \r\n\r\n\tmaailma\n")
}
    func testDamagedMarkersFallbackWithoutDroppingContent() async throws {
        let engine=PageEngine(preserveMarkers:false)
        let output=try await PageTranslationProcessor.translate(page([.init(id:"a",text:"Hello"),.init(id:"b",text:"world")]),from:"en",to:"fi",engine:engine){_ in}
        XCTAssertEqual(output.translations.map(\.text),["Hei","maailma"]);XCTAssertEqual(output.fallbackGroups,1)
        XCTAssertNil(PageTranslationProcessor.unpack("__MM0__ first __MM0__ duplicate __MM1__",count:1))
        XCTAssertNil(PageTranslationProcessor.unpack("__MM0__ __MM1__",count:1))
    }
    func testLongRunIsBoundedAndKeepsParagraphs() async throws {
        let text=String(repeating:"Hello world. ",count:180)+"\n\nHello"
        let engine=PageEngine();let result=try await PageTranslationProcessor.translate(page([.init(id:"a",text:text)]),from:"en",to:"fi",engine:engine){_ in}
        let calls=await engine.calls;XCTAssertGreaterThan(calls.count,2);XCTAssertTrue(calls.allSatisfy{$0.count<=800})
        XCTAssertEqual(result.translations[0].text.components(separatedBy:"maailma").count-1,180)
        XCTAssertTrue(result.translations[0].text.hasSuffix("\n\nHei"))
    }
    func testCancellationUnloadsAndReturnsNoPartialPage() async throws {
        let engine=PageEngine();await engine.setCancelled()
        do { _ = try await PageTranslationProcessor.translate(page([.init(id:"a",text:"Hello")]),from:"en",to:"fi",engine:engine){_ in};XCTFail("Cancellation should throw") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let unloaded=await engine.didUnload;XCTAssertTrue(unloaded)
    }
    func testDuplicateIDsAndOversizedPageRejected() {
        XCTAssertThrowsError(try page([.init(id:"a",text:"Hello"),.init(id:"a",text:"world")]).validate())
        XCTAssertThrowsError(try page([.init(id:"a",text:String(repeating:"a",count:200001))]).validate())
    }
}
