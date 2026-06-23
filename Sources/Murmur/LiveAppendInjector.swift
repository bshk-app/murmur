import Foundation
import MurmurKit

/// Progressively types **confirmed** (Voxtral) words into the focused field as
/// they arrive during a dictation hold — append-only, never rewriting already
/// typed text.
///
/// This relies on the two-tier contract that `confirmed` is monotonic: Voxtral
/// does not revise a word once committed, so the confirmed string only ever
/// grows by whole words. We track how many words we've already typed and inject
/// just the new tail. The volatile Nemotron `partial` is deliberately **not**
/// injected — it's display-only (HUD/console); the field gets only stable text.
///
/// `@unchecked Sendable` + `NSLock`: `appendConfirmed` is driven from the mic
/// capture queue while `begin`/`flushFinal` run from the controller's release
/// path. The lock guards the word counter; the slow `TextInjector.type` (CGEvent
/// posting) always runs *outside* the lock so it never blocks the capture queue.
final class LiveAppendInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var injectedWords = 0
    private var enabled = false

    /// Reset for a new utterance. `enabled` should be `Accessibility.isTrusted`
    /// at the moment recording starts — if we can't type, we inject nothing and
    /// leave the final-flush prompt path to handle the grant.
    func begin(enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        injectedWords = 0
        self.enabled = enabled
    }

    /// Type any confirmed words not yet injected. Pass the growing confirmed
    /// string each update; safe to call every chunk (no-op when nothing new).
    func appendConfirmed(_ confirmed: String) {
        guard let chunk = nextChunk(from: confirmed) else { return }
        TextInjector.type(chunk)
    }

    /// Release: type whatever confirmed tail wasn't injected yet, plus a trailing
    /// space to separate this utterance from the next. Run off the main thread.
    func flushFinal(_ final: String) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        lock.unlock()
        let tail = nextChunk(from: final) ?? ""
        TextInjector.type(tail + " ")
    }

    /// The not-yet-typed suffix of `text` (whole words only), advancing the
    /// counter. Returns nil when disabled or nothing new. The leading space is
    /// included for every chunk after the first so words stay separated.
    private func nextChunk(from text: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return nil }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard words.count > injectedWords else { return nil }
        let isFirst = injectedWords == 0
        let fresh = words[injectedWords...].joined(separator: " ")
        injectedWords = words.count
        return isFirst ? fresh : " " + fresh
    }
}
