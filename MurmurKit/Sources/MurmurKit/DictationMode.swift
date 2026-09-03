import Foundation
import MLXAudioSTT

/// Which model(s) transcribe an utterance.
public enum DictationMode: String, Sendable, CaseIterable {
    case fast       // Nemotron only — instant draft, no batch final
    case hybrid     // Nemotron live draft + Parakeet batch final
    case accurate   // Parakeet batch only — no live draft
}

extension DictationMode {
    /// Languages where Nemotron's streaming preview is unreliable, so the live
    /// draft stays down and only the Parakeet batch runs.
    ///
    /// This is a property of the fast model, not of the language's difficulty:
    /// on these five it emits confident wrong tokens that the corrector then
    /// has to overwrite, and an empty screen for a moment beats text that
    /// rewrites itself under the reader. Ported from the routing matrix in
    /// dictator's `shared/catalog.py` (`NO_FAST_LOOP`), which measured it.
    ///
    /// Written as language codes without regions: the picker offers `zh` and
    /// `zh-Hans` for one prompt id, and both must gate the same way.
    public static let languagesWithoutLiveDraft: Set<String> = [
        "ar", "ja", "ko", "zh", "vi",
    ]

    /// Whether this language may run the fast lane at all.
    public static func allowsLiveDraft(language: String?) -> Bool {
        guard let language else { return true }
        // "auto" cannot be gated: the language is not known until the model has
        // already produced text, so gating it would disable the live draft for
        // everyone. The risk is accepted and confined to automatic detection.
        let base = language.split(separator: "-").first.map(String.init) ?? language
        return !languagesWithoutLiveDraft.contains(base.lowercased())
    }

    /// The mode that will actually run for `language`.
    ///
    /// Downgrades rather than refuses: a user who asked for Hybrid in Japanese
    /// wants dictation, and `.accurate` is the same transcript without the
    /// misleading preview. `.fast` has no batch lane to fall back to, so it
    /// becomes `.accurate` too.
    public func effective(for language: String?) -> DictationMode {
        guard !DictationMode.allowsLiveDraft(language: language) else { return self }
        switch self {
        case .fast, .hybrid: return .accurate
        case .accurate: return .accurate
        }
    }

    /// Modes worth offering for `language`; the picker should not show a choice
    /// that silently becomes another one.
    public static func available(for language: String?) -> [DictationMode] {
        allowsLiveDraft(language: language) ? allCases : [.accurate]
    }
}

/// The common surface STTEngine drives per utterance, regardless of mode.
protocol UtteranceSession {
    func step(_ samples: [Float]) -> (confirmed: String, partial: String)
    var currentText: (confirmed: String, partial: String) { get }
    func finishText() -> String
    /// Stop the live lane; later `step`s must still keep the final audio.
    func releaseLive()
}

extension UtteranceSession {
    func releaseLive() {}
}

/// Fast lane only (Nemotron). Its accumulated text is the confirmed output; there
/// is no provisional tail because there's no slower lane to refine against.
final class NemotronOnlySession: UtteranceSession {
    private let s: NemotronASRStreamSession
    init(_ model: NemotronASRModel, language: String?, chunkMs: Int) {
        s = model.makeStreamSession(language: language, chunkMs: chunkMs)
    }
    func step(_ samples: [Float]) -> (confirmed: String, partial: String) {
        _ = s.step(samples); return (s.text, "")
    }
    var currentText: (confirmed: String, partial: String) { (s.text, "") }
    func finishText() -> String { _ = s.finish(); return s.text }
}
