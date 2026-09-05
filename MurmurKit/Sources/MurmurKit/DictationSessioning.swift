import Foundation

/// The part of `DictationSession` the menu-bar app actually drives.
///
/// Deliberately seven members rather than the whole class: the offline, paced
/// and diagnostic entry points exist for the CLI and the benchmarks, and a
/// substitute that had to implement them would be too expensive to write for
/// the thing it is usually needed for - checking what the controller did
/// *around* a session, not inside one.
///
/// It exists because `beginRecording` was unreachable from tests. Everything
/// it decides - which language the recogniser is handed, which lane really
/// runs after `effective(for:)`, and the values latched from both - was
/// verifiable only by reading it, and two separate mutation runs confirmed
/// that deleting a latch broke nothing any test could see.
///
/// `Sendable` is required, not incidental: `endRecording` calls `stop()` from
/// a detached task, so a session that could not cross that boundary would not
/// be usable as a session at all.
public protocol DictationSessioning: AnyObject, Sendable {
    /// Live update per fed chunk: `(confirmed, provisional)`, on the capture queue.
    var onUpdate: ((_ confirmed: String, _ partial: String) -> Void)? { get set }

    /// Ready to record in `mode` — its models are loaded and warmed.
    func isReady(_ mode: DictationMode) -> Bool

    /// Backs the language picker.
    var supportedLanguageCodes: [String] { get }

    /// Download + load + warm up only the models `mode` needs. Heavy.
    func load(mode: DictationMode) async throws

    /// Surface the microphone permission prompt early (no-op once granted).
    func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void)

    func start(mode: DictationMode, language: String?, microphoneUID: String?) throws

    /// Stop capture, run the batch final, return that transcript.
    @discardableResult
    func stop() -> String
}

/// The real one. Default arguments on the class still satisfy requirements
/// written without them, so nothing about `DictationSession` changes.
extension DictationSession: DictationSessioning {}

public extension DictationSessioning {
    /// Default arguments on the concrete class satisfy a requirement written
    /// without them, but they do not reach callers going through the
    /// protocol - so the fire-and-forget spelling is restored here rather
    /// than by making every call site pass an empty closure.
    func requestMicrophonePermission() { requestMicrophonePermission { _ in } }
}
