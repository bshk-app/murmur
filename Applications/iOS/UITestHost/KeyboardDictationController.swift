import SwiftUI
import MurmurCore

@MainActor @Observable final class KeyboardDictationController {
    var configuration = KeyboardConfiguration()
    var state = KeyboardSessionState()
    var isActive = false
    var hasPendingPreparation = false
    var detail = ""
    var summaryTitle: String {
        switch state.phase { case .preparing: return "Preparing…"; case .recording: return "Listening"; case .finalizing: return "Refining"; case .ready, .result: return "Ready to dictate"; case .inactive, .failed: return "Activation needed" }
    }
    var microphoneAllowed = true
    var fullAccessConfirmed = true
    var modelsReady: Bool { isActive && [.ready, .recording, .finalizing, .result].contains(state.phase) }
    var languages: [(code: String, name: String)] { AppLanguages.all.filter { SpeechModelChoice.parakeetLanguages.contains($0.code) } }
    func enable() async { state.error = L10n.text("Speech engines are tested on a physical iPhone. This simulator only tests the interface.") }
    var translationLanguages: [(code: String, name: String)] { LanguagePair.qualityLanguages.sorted().map { ($0, AppLanguages.name($0)) } }
    func activateFromKeyboard() async { await enable() }
    func end(message: String? = nil) async { isActive = false }
    func stopAndEnd() async { await end() }
}
