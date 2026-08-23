import Foundation
import MLXAudioSTT

/// Which model(s) transcribe an utterance.
public enum DictationMode: String, Sendable, CaseIterable {
    case fast       // Nemotron only — instant draft, no batch final
    case hybrid     // Nemotron live draft + Parakeet batch final
    case accurate   // Parakeet batch only — no live draft
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
