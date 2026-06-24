import Foundation
import MLXAudioSTT

/// Which model(s) transcribe an utterance.
public enum DictationMode: String, Sendable, CaseIterable {
    case fast       // Nemotron only — instant draft, lighter, lower accuracy
    case hybrid     // two-tier: Nemotron draft + Voxtral refine (the default)
    case accurate   // Voxtral only — accurate, no instant draft, higher latency
}

/// The common surface STTEngine drives per utterance, regardless of mode.
protocol UtteranceSession {
    func step(_ samples: [Float]) -> (confirmed: String, partial: String)
    var currentText: (confirmed: String, partial: String) { get }
    func finishText() -> String
}

/// Two-tier (hybrid) lane: `step` already returns the confirmed/provisional split.
extension TwoTierSession: UtteranceSession {
    var currentText: (confirmed: String, partial: String) { (confirmed, partial) }
    func finishText() -> String { finish().confirmed }
}

/// Fast lane only (Nemotron). Its accumulated text is the confirmed output; there
/// is no provisional tail because there's no slower lane to refine against.
final class NemotronOnlySession: UtteranceSession {
    private let s: NemotronASRStreamSession
    init(_ model: NemotronASRModel, language: String?, chunkMs: Int) {
        s = model.makeStreamSession(language: language, chunkMs: chunkMs)
    }
    func step(_ samples: [Float]) -> (confirmed: String, partial: String) { _ = s.step(samples); return (s.text, "") }
    var currentText: (confirmed: String, partial: String) { (s.text, "") }
    func finishText() -> String { _ = s.finish(); return s.text }
}

/// Accurate lane only (Voxtral native streaming).
final class VoxtralOnlySession: UtteranceSession {
    private let s: VoxtralRealtimeStreamSession
    init(_ model: VoxtralRealtimeModel, delayMs: Int?) {
        s = model.makeStreamSession(transcriptionDelayMs: delayMs)
    }
    func step(_ samples: [Float]) -> (confirmed: String, partial: String) { _ = s.step(samples); return (s.text, "") }
    var currentText: (confirmed: String, partial: String) { (s.text, "") }
    func finishText() -> String { _ = s.finish(); return s.text }
}
