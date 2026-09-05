@testable import MurmurKit

/// A `PhraseTranslating` that answers instantly and touches nothing.
///
/// `DictationController.translateCaptions` starts real work, so any test that
/// calls it with the default `CaptionTranslator` loads native bergamot weights
/// on Swift's cooperative pool. That is not hypothetical: this app has a
/// SIGSEGV on record from exactly that path (deep `YAML::RegEx::MatchUnchecked`
/// recursion while parsing `config.bergamot.yml`, 2026-09-05, debug build).
/// Tests about stamping, ordering, or the HUD badge decide what they assert
/// before any translation happens, so they should never pay for a model.
///
/// Inject with `controller.captionTranslation = CaptionTranslator(service: InertTranslator())`
/// and drain with `await controller.captionTranslateTask?.value`.
struct InertTranslator: PhraseTranslating {
    func translateOrEmpty(_ text: String, from source: String, to target: String) async -> String {
        "[\(target)] \(text)"
    }
}
