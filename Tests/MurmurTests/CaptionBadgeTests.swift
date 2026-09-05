import XCTest
@testable import Murmur
@testable import MurmurKit

/// The HUD's `RU → EN` badge is stamped once by `HUDController.begin`, which
/// is enough for dictation: one utterance, one setting. Captions run for as
/// long as the talk does and the Translate-to picker stays live throughout,
/// so the badge has to follow the setting rather than the value captured at
/// the start - otherwise the header says `RU → EN` over a second line that is
/// now German, or over no second line at all.
///
/// Every test here injects a fake translator and drains the task it starts.
/// `translateCaptions` kicks off real work, and with a real `CaptionTranslator`
/// that means loading native bergamot weights on the cooperative pool - which
/// is exactly where this app has crashed before (`YAML::RegEx::MatchUnchecked`
/// recursion, SIGSEGV, 2026-09-05). A badge test has no business touching a
/// model, and none should outlive its own `func`.
@MainActor
final class CaptionBadgeTests: XCTestCase {
    private var savedTarget: String?

    override func setUpWithError() throws {
        savedTarget = UserDefaults.standard.string(forKey: TranslationSetting.key)
    }

    override func tearDownWithError() throws {
        if let savedTarget {
            UserDefaults.standard.set(savedTarget, forKey: TranslationSetting.key)
        } else {
            UserDefaults.standard.removeObject(forKey: TranslationSetting.key)
        }
    }

    private func target(_ value: String) {
        UserDefaults.standard.set(value, forKey: TranslationSetting.key)
    }

    private func snapshot(_ revision: UInt64) -> CaptionSnapshot {
        CaptionSnapshot(revision: revision, confirmed: [], provisional: "Раз, два, три")
    }

    /// A caption talk already on screen, translating ru -> en, exactly as
    /// `beginCaptions` leaves things - but with a fake translator in place of
    /// the native one.
    private func talking() -> DictationController {
        let controller = DictationController()
        controller.captionTranslation = CaptionTranslator(service: InertTranslator())
        target("en")
        controller.captionSource = "ru"
        controller.captionTarget = "en"
        controller.hud.begin(lang: "RU", target: "EN")
        return controller
    }

    /// Run a snapshot through and wait for the work it started, so no
    /// translation task survives the test that spawned it.
    private func feed(_ controller: DictationController, _ revision: UInt64) async {
        controller.translateCaptions(snapshot(revision))
        await controller.captionTranslateTask?.value
    }

    func testTheBadgeFollowsATargetChangedMidTalk() async {
        let controller = talking()
        await feed(controller, 1)
        XCTAssertEqual(controller.hud.model.target, "EN", "baseline: the talk started as ru -> en")

        // The user reopens the menu mid-talk and picks German.
        target("de")
        await feed(controller, 2)

        XCTAssertEqual(controller.hud.model.target, "DE",
                       "the second line is German now; a header still reading EN would be lying")
    }

    /// Switching translation off takes the second line away (`showTranslation("")`
    /// clears it). A leftover target would leave an arrow pointing at nothing.
    func testTheBadgeClearsWhenTranslationIsSwitchedOffMidTalk() async {
        let controller = talking()
        await feed(controller, 1)
        XCTAssertEqual(controller.hud.model.target, "EN")

        target(TranslationSetting.off)
        await feed(controller, 2)

        XCTAssertEqual(controller.hud.model.target, "",
                       "no second line means no arrow in the header")
    }

    /// The badge and the translation are gated on the same predicate, so an
    /// unroutable target must drop the arrow rather than promise a language
    /// the pill will never show.
    func testTheBadgeClearsWhenTheNewTargetIsUnroutable() async {
        let controller = talking()
        await feed(controller, 1)

        target("xx")
        XCTAssertNil(LanguagePair.route(from: "ru", to: "xx"),
                     "xx is expected to be unsupported; test assumption is stale")
        await feed(controller, 2)

        XCTAssertEqual(controller.hud.model.target, "")
    }
}
