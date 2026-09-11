import Foundation
import MurmurCore

/// Explicit simulator fixtures for design captures and UI flows. Not linked into the app.
actor UIHostTextTranslationEngine: TextTranslationEngine {
    nonisolated func availableQualities(from: String, to: String) -> [ProcessingQuality] { ProcessingQuality.translationOptions(from: from, to: to) }
    enum Scenario { case success, preparing, translating, failure }
    private let scenario: Scenario
    private let result: String?
    private var loaded = false
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    init(scenario: Scenario = .success, result: String? = nil) { self.scenario = scenario; self.result = result }
    private var uiTest: Bool { ProcessInfo.processInfo.arguments.contains { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) == "textTranslationUITest" } }
    var residentModelCount: Int { loaded ? 1 : 0 }
    private func hold() async { if !released { await withCheckedContinuation { waiting = $0 } } }
    func release() { released = true; waiting?.resume(); waiting = nil }
    func prepare(from: String, to: String, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        guard ProcessInfo.processInfo.arguments.contains("--design-capture") || uiTest else { throw CocoaError(.featureUnsupported) }
        if scenario == .failure { throw CocoaError(.fileReadNoSuchFile) }
        await onProgress(scenario == .preparing ? 0.36 : 1)
        if scenario == .preparing { await hold() }
    }
    func translate(_ text: String, from: String, to: String) async throws -> String {
        if scenario == .translating { await hold() }
        loaded = true
        if uiTest && !ProcessInfo.processInfo.arguments.contains("--design-capture") { return "UI test translation" }
        return result ?? "Lähetän asiakirjat huomenna.\n\nVoimmeko tavata kello kolme?"
    }
    func unload() async { loaded = false }
}
