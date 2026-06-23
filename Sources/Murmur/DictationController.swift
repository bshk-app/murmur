import AppKit
import Foundation
import KeyboardShortcuts
import MurmurKit
import Observation

/// Thin SwiftUI-facing wrapper around `MurmurKit.DictationSession`: maps the
/// shared pipeline to an `@Observable` menu-bar state, wires the Carbon hotkey
/// to start/stop, and injects the final transcript into the focused field.
///
/// All the heavy lifting (mic, STT, 480 ms feed, warm-up) lives in MurmurKit and
/// is shared verbatim with `murmur-cli`.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case loadingModels
        case idle
        case recording
        case transcribing
        case transcribed(String)
        case error(String)
    }

    private(set) var state: State = .loadingModels

    private let session = DictationSession()
    private let liveInjector = LiveAppendInjector()
    private var promptedAccessibility = false

    var shortcutLabel: String {
        KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "⌃⌥Space"
    }

    /// Typing into other apps needs Accessibility (the hotkey itself does not).
    var needsAccessibilityToType: Bool { !Accessibility.isTrusted }

    var statusLine: String {
        switch state {
        case .loadingModels: return "Loading models…"
        case .idle: return "Idle — hold \(shortcutLabel)"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case let .transcribed(t): return t.isEmpty ? "…(no speech detected)" : t
        case let .error(m): return "Error: \(m)"
        }
    }

    func bootstrap() {
        session.onUpdate = { [weak self] confirmed, partial in self?.echo(confirmed, partial) }
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.beginRecording() }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.endRecording() }
        session.requestMicrophonePermission()            // surface the mic prompt early
        loadModels()
    }

    func requestAccessibility() { Accessibility.prompt() }

    private func loadModels() {
        state = .loadingModels
        Task { @MainActor in
            do {
                try await session.load()
                if state == .loadingModels { state = .idle }
            } catch {
                state = .error("model load: \(error.localizedDescription)")
            }
        }
    }

    private func beginRecording() {
        guard session.isLoaded, state != .recording, state != .transcribing else { return }
        do {
            // Live-type confirmed words during the hold only if we can already
            // type; otherwise stay quiet and let the release path prompt once.
            liveInjector.begin(enabled: Accessibility.isTrusted)
            try session.start()
            state = .recording
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Runs on the mic capture queue (via `onUpdate`). Two jobs:
    ///  1. live-type newly confirmed (Voxtral) words into the focused field —
    ///     append-only, the volatile `partial` is never injected (model A);
    ///  2. echo the two-tier view (confirmed prefix + fast Nemotron tail in ⟨⟩),
    ///     redrawn in place. The HUD (a later step) is the in-app home for the
    ///     ⟨⟩ tail; the console echo helps when running from Xcode.
    private nonisolated func echo(_ confirmed: String, _ partial: String) {
        liveInjector.appendConfirmed(confirmed)
        let line = partial.isEmpty ? confirmed : "\(confirmed) ⟨\(partial)⟩"
        let tail = line.count > 100 ? "…" + String(line.suffix(100)) : line
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(tail)".utf8))
    }

    private func endRecording() {
        guard state == .recording else { return }
        state = .transcribing
        // Drain, then type the remaining confirmed tail — both off the main thread
        // so neither a slow finish nor the CGEvent typing freezes the UI. Most of
        // the words were already injected live during the hold; flushFinal adds
        // whatever Voxtral committed on flush, plus a trailing space.
        Task.detached(priority: .userInitiated) { [session, liveInjector] in
            let final = session.stop()
            liveInjector.flushFinal(final)
            await MainActor.run { [weak self] in
                guard let self else { return }
                FileHandle.standardError.write(Data("\n".utf8))
                // Nothing was typed because we lack Accessibility — ask once.
                if !final.isEmpty, !Accessibility.isTrusted, !self.promptedAccessibility {
                    self.promptedAccessibility = true
                    Accessibility.prompt()
                }
                self.state = .transcribed(final)
            }
        }
    }
}
