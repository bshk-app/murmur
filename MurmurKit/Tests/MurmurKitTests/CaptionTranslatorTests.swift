import XCTest
@testable import MurmurKit

/// Counts every call, so "did this phrase get translated again?" is answerable.
private actor SpyTranslator: PhraseTranslating {
    private(set) var calls: [String] = []
    private var replies: [String: String] = [:]

    func reply(_ translation: String, for source: String) { replies[source] = translation }
    func log() -> [String] { calls }

    func translateOrEmpty(_ text: String, from source: String, to target: String) async -> String {
        calls.append(text)
        return replies[text] ?? "<\(text)>"
    }
}

final class CaptionTranslatorTests: XCTestCase {
    private func segment(_ id: UInt64, _ text: String) -> CaptionSegment {
        CaptionSegment(id: id, startSample: 0, endSample: 1, text: text, state: .confirmed)
    }

    /// The reason this type exists. Captions emit a snapshot several times a
    /// second; translating the whole transcript each time would re-translate
    /// every sentence hundreds of times over a talk.
    func testAnUnchangedPhraseIsTranslatedOnlyOnce() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)
        let segments = [segment(1, "привет"), segment(2, "как дела")]

        for _ in 0..<25 {
            _ = await translator.translation(of: segments, from: "ru", to: "en")
        }

        let calls = await spy.log()
        XCTAssertEqual(calls, ["привет", "как дела"],
                       "phrases were re-translated on later snapshots")
    }

    /// The batch pass rewrites a phrase in place. Keying the cache on the id
    /// alone would keep showing the translation of text that no longer exists.
    func testACorrectedPhraseIsTranslatedAgain() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)

        _ = await translator.translation(of: [segment(1, "как дила")], from: "ru", to: "en")
        let line = await translator.translation(of: [segment(1, "как дела")], from: "ru", to: "en")

        let calls = await spy.log()
        XCTAssertEqual(calls, ["как дила", "как дела"])
        XCTAssertEqual(line, "<как дела>", "the stale translation survived a correction")
    }

    func testPhrasesAreJoinedInTranscriptOrder() async {
        let spy = SpyTranslator()
        await spy.reply("one", for: "раз")
        await spy.reply("two", for: "два")
        let translator = CaptionTranslator(service: spy)

        let line = await translator.translation(
            of: [segment(1, "раз"), segment(2, "два")], from: "ru", to: "en")
        XCTAssertEqual(line, "one two")
    }

    /// Nothing closed yet reads on screen as a HUD with no second line, rather
    /// than an empty one under a hairline.
    func testNothingConfirmedGivesNoLine() async {
        let translator = CaptionTranslator(service: SpyTranslator())
        let line = await translator.translation(of: [], from: "ru", to: "en")
        XCTAssertTrue(line.isEmpty)
    }

    func testBlankPhrasesAreSkipped() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)
        _ = await translator.translation(
            of: [segment(1, "   "), segment(2, "текст")], from: "ru", to: "en")
        let calls = await spy.log()
        XCTAssertEqual(calls, ["текст"], "whitespace was sent to the engine")
    }

    /// A talk can run for an hour; the cache must not grow with every phrase
    /// the transcript has already dropped.
    func testDroppedPhrasesAreForgotten() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)

        _ = await translator.translation(of: [segment(1, "первое")], from: "ru", to: "en")
        // Segment 1 scrolls out of the transcript, then its id is seen again
        // with different text — a stale entry would answer for it.
        _ = await translator.translation(of: [segment(2, "второе")], from: "ru", to: "en")
        _ = await translator.translation(of: [segment(1, "первое")], from: "ru", to: "en")

        let calls = await spy.log()
        XCTAssertEqual(calls, ["первое", "второе", "первое"])
    }

    /// Realtime: the live tail is translated too, so the second line moves with
    /// the speaker instead of waiting for the phrase to close.
    func testTheLiveDraftIsTranslated() async {
        let spy = SpyTranslator()
        await spy.reply("hello", for: "привет")
        await spy.reply("how are", for: "как де")
        let translator = CaptionTranslator(service: spy)

        let line = await translator.translation(
            of: [segment(1, "привет")], draft: "как де", from: "ru", to: "en")
        XCTAssertEqual(line, "hello how are")
    }

    /// The draft is re-emitted far more often than it changes wording; an
    /// uncached tail would re-translate the same string many times a second.
    func testAnUnchangedDraftIsNotRetranslated() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)

        for _ in 0..<10 {
            _ = await translator.translation(of: [], draft: "как дела", from: "ru", to: "en")
        }
        let calls = await spy.log()
        XCTAssertEqual(calls, ["как дела"], "the live tail was re-translated while unchanged")
    }

    /// As the speaker carries on, each new wording is translated once.
    func testAGrowingDraftIsTranslatedPerWording() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)

        for tail in ["как", "как де", "как дела"] {
            _ = await translator.translation(of: [], draft: tail, from: "ru", to: "en")
        }
        let calls = await spy.log()
        XCTAssertEqual(calls, ["как", "как де", "как дела"])
    }

    /// Omitting the draft keeps the old behaviour: settled phrases only.
    func testWithoutADraftOnlyConfirmedPhrasesAreTranslated() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)
        _ = await translator.translation(of: [segment(1, "привет")], from: "ru", to: "en")
        let calls = await spy.log()
        XCTAssertEqual(calls, ["привет"])
    }

    func testResetClearsEverything() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)
        let segments = [segment(1, "привет")]

        _ = await translator.translation(of: segments, from: "ru", to: "en")
        await translator.reset()
        _ = await translator.translation(of: segments, from: "ru", to: "en")

        let calls = await spy.log()
        XCTAssertEqual(calls, ["привет", "привет"], "a new talk inherited the old cache")
    }
}
