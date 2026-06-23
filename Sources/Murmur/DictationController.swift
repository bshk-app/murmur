import AppKit
import Foundation
import KeyboardShortcuts
import Observation

/// Wires the global push-to-talk hotkey + mic capture to the on-device two-tier
/// STT engine and exposes a human-readable status for the menu bar.
///
/// The hotkey is Carbon-based (KeyboardShortcuts) so it needs no permission.
/// Accessibility is required only to *type* the result into other apps.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case loadingModels
        case idle
        case recording
        case transcribed(String)
        case error(String)
    }

    private(set) var state: State = .loadingModels

    private var mic = MicCapture()
    private let engine = STTEngine()
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
        case let .transcribed(t): return t.isEmpty ? "…(no speech detected)" : t
        case let .error(m): return "Error: \(m)"
        }
    }

    func bootstrap() {
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.beginRecording() }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.endRecording() }
        MicCapture.requestPermission { _ in }            // surface the mic prompt early
        loadModels()
    }

    func requestAccessibility() { Accessibility.prompt() }

    private func loadModels() {
        state = .loadingModels
        Task { @MainActor in
            do {
                try await engine.load()
                if state == .loadingModels { state = .idle }
            } catch {
                state = .error("model load: \(error.localizedDescription)")
            }
        }
    }

    private func beginRecording() {
        guard engine.isLoaded, state != .recording else { return }
        engine.begin(language: nil)
        mic.onChunk = { [weak self] chunk in self?.feed(chunk) }
        do {
            try mic.start()
            state = .recording
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Runs on the mic capture queue. Streams the two-tier line to the console:
    /// Voxtral-confirmed prefix + Nemotron provisional tail in ⟨⟩.
    private nonisolated func feed(_ chunk: [Float]) {
        let (confirmed, partial) = engine.step(chunk)
        let line = partial.isEmpty ? confirmed : "\(confirmed) ⟨\(partial)⟩"
        if !line.isEmpty { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }

    private func endRecording() {
        guard state == .recording else { return }
        _ = mic.stop()                                   // flushes the trailing chunk
        let final = engine.finish()
        mic = MicCapture()                               // fresh engine for the next gesture
        FileHandle.standardError.write(Data("\n".utf8))
        if !final.isEmpty {
            if Accessibility.isTrusted {
                TextInjector.type(final + " ")           // into the focused field of any app
            } else if !promptedAccessibility {
                promptedAccessibility = true             // ask once; transcript still shown in menu
                Accessibility.prompt()
            }
        }
        state = .transcribed(final)
    }
}
