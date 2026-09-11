import XCTest
import MurmurCore
import MurmurTranslation

final class ModelStorageDependencyTests: XCTestCase {
    func testRemovingPivotLegInvalidatesOnlyRoutesThatUseThatTier() {
        let service=TranslationService(modelsRoot:URL(fileURLWithPath:"/nonexistent-model-storage-test"))
        let enfi=LanguagePair(source:"en",target:"fi")
        XCTAssertTrue(service.usesDownloadedModel(enfi,from:"de",to:"fi",quality:true))
        XCTAssertFalse(service.usesDownloadedModel(enfi,from:"ru",to:"fi",quality:true),"Russian–Finnish has its own direct quality model")
        XCTAssertTrue(service.usesDownloadedModel(enfi,from:"ru",to:"fi",quality:false),"Voice preview still uses its English pivot")
        XCTAssertFalse(service.usesDownloadedModel(enfi,from:"fi",to:"de",quality:true))
        XCTAssertTrue(service.usesDownloadedModel(.init(source:"ru",target:"fi"),from:"ru",to:"fi",quality:true))
    }
}
