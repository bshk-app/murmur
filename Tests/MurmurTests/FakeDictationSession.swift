import Foundation
@testable import MurmurKit

/// A session that records what it was asked to do and does none of it.
///
/// The point is not to simulate dictation - it is to make `beginRecording`
/// reachable at all. The real session needs loaded weights and a microphone,
/// so everything the controller decides *before* handing work over was
/// previously unverifiable.
///
/// `@unchecked Sendable`: `DictationSessioning` requires `Sendable` because
/// `endRecording` calls `stop()` from a detached task. Every test here drives
/// it from the main actor and only reads it after the call it is asserting
/// about, so the mutable boxes are not actually shared across threads.
final class FakeDictationSession: DictationSessioning, @unchecked Sendable {
    var onUpdate: ((String, String) -> Void)?

    /// What `isReady` answers. `beginRecording` bails out to `prepare` when
    /// this is false, so a test that forgets it silently exercises nothing.
    var ready = true
    var supportedLanguageCodes: [String] = ["en", "ru", "ja"]

    /// Thrown from `start` when set, to drive the failure path.
    var startError: Error?

    // What the recogniser was actually handed.
    private(set) var startedMode: DictationMode?
    private(set) var startedLanguage: String?
    private(set) var startCount = 0

    func isReady(_ mode: DictationMode) -> Bool { ready }
    func load(mode: DictationMode) async throws {}
    func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) { completion(true) }

    func start(mode: DictationMode, language: String?, microphoneUID: String?) throws {
        if let startError { throw startError }
        startedMode = mode
        startedLanguage = language
        startCount += 1
    }

    func stop() -> String { "" }
}
