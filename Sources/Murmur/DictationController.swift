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
    private var promptedAccessibility = false

    /// Confirmed text already echoed to the console (reset per utterance).
    /// Touched only from `echo` on the mic queue (and reset before capture starts).
    @ObservationIgnored nonisolated(unsafe) private var lastConfirmed = ""

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
        session.onUpdate = { [weak self] confirmed, _ in self?.echo(confirmed) }
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
        lastConfirmed = ""
        do {
            try session.start()
            state = .recording
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Runs on the mic capture queue (via `onUpdate`). Echoes only newly-confirmed
    /// text — printing the whole growing line every chunk floods stderr.
    private nonisolated func echo(_ confirmed: String) {
        guard confirmed.hasPrefix(lastConfirmed), confirmed.count > lastConfirmed.count else {
            lastConfirmed = confirmed
            return
        }
        FileHandle.standardError.write(Data(confirmed.suffix(confirmed.count - lastConfirmed.count).utf8))
        lastConfirmed = confirmed
    }

    private func endRecording() {
        guard state == .recording else { return }
        state = .transcribing
        // Drain + flush off the main thread so a slow finish never freezes the UI.
        Task.detached(priority: .userInitiated) { [session] in
            let final = session.stop()
            await MainActor.run { [weak self] in
                guard let self else { return }
                FileHandle.standardError.write(Data("\n".utf8))
                if !final.isEmpty {
                    if Accessibility.isTrusted {
                        TextInjector.type(final + " ")   // into the focused field of any app
                    } else if !self.promptedAccessibility {
                        self.promptedAccessibility = true
                        Accessibility.prompt()
                    }
                }
                self.state = .transcribed(final)
            }
        }
    }
}
