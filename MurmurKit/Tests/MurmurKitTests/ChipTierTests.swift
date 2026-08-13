import XCTest
@testable import MurmurKit

final class ChipTierTests: XCTestCase {
    func test_tier_is_read_from_the_cpu_brand_string() {
        XCTAssertEqual(ChipTier.parse("Apple M1"), .base)
        XCTAssertEqual(ChipTier.parse("Apple M4"), .base)
        XCTAssertEqual(ChipTier.parse("Apple M1 Pro"), .pro)
        XCTAssertEqual(ChipTier.parse("Apple M3 Max"), .max)
        XCTAssertEqual(ChipTier.parse("Apple M2 Ultra"), .ultra)
    }

    /// Hybrid measures RTF 0.83 on an M1 Max and 4–10 on a base M1 — the 4 B
    /// accurate lane needs bandwidth a base part does not have. Recommending it
    /// there hands someone a mode their machine cannot run.
    func test_only_pro_and_above_are_recommended_hybrid() {
        XCTAssertEqual(ChipTier.base.recommendedMode, .fast)
        XCTAssertEqual(ChipTier.pro.recommendedMode, .hybrid)
        XCTAssertEqual(ChipTier.max.recommendedMode, .hybrid)
        XCTAssertEqual(ChipTier.ultra.recommendedMode, .hybrid)
    }

    /// An unrecognised chip gets the mode that works everywhere, not the one that
    /// needs the most from the machine.
    func test_an_unknown_chip_is_not_assumed_to_be_fast_hardware() {
        XCTAssertEqual(ChipTier.parse("Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz"), .unknown)
        XCTAssertEqual(ChipTier.unknown.recommendedMode, .fast)
    }
}
