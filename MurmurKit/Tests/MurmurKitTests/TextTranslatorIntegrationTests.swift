import XCTest
import MurmurCore
import MurmurTranslation

@MainActor final class TextTranslatorIntegrationTests: XCTestCase {
    func testTypedParagraphsUseInstalledModelsAndReleaseMemory() async throws {
        guard let path = ProcessInfo.processInfo.environment["MURMUR_TEXT_NATIVE_ROOT"] else { throw XCTSkip("Local quality model packs required") }
        let root = URL(fileURLWithPath: path)
        for (from, to, input) in [
            ("en", "de", "I will send the documents tomorrow.\n\nCan we meet at three?"),
            ("de", "fr", "Ich schicke die Dokumente morgen.\n\nKönnen wir uns um drei treffen?")
        ] {
            let engine = TextTranslationSession(modelsRoot: root)
            let model = TextTranslationModel(engine: engine, source: from, target: to,
                availableTargets: { TextTranslationSession.availableTargets(from: $0, modelsRoot: root) })
            model.input = input
            await model.start()?.value
            XCTAssertNil(model.error); XCTAssertFalse(model.isBusy)
            XCTAssertEqual(model.input, input)
            XCTAssertFalse(model.output.isEmpty); XCTAssertNotEqual(model.output, input)
            XCTAssertTrue(model.output.contains("\n"), "Paragraph structure must survive")
            XCTAssertTrue(model.modelsLoaded)
            print("TEXT_TRANSLATOR \(from)-\(to): \(model.output)")
            await model.unload()
            let remaining = await engine.residentModelCount
            XCTAssertEqual(remaining, 0); XCTAssertFalse(model.modelsLoaded)
        }
    }
}
