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
        case transcribing
        case transcribed(String)
        case error(String)
    }

    private(set) var state: State = .loadingModels

    private var mic = MicCapture()
    private let engine = STTEngine()
    private var promptedAccessibility = false

    /// Confirmed text already echoed to the console (reset per utterance).
    /// Touched only from `feed` on the mic queue (and reset before capture starts).
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
        guard engine.isLoaded, state != .recording, state != .transcribing else { return }
        engine.begin(language: nil)
        lastConfirmed = ""
        mic.onChunk = { [weak self] chunk in self?.feed(chunk) }
        do {
            try mic.start()
            state = .recording
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Runs on the mic capture queue. Echoes only newly-confirmed text — printing
    /// the whole growing line every 80 ms floods stderr and stalls the pipeline.
    private nonisolated func feed(_ chunk: [Float]) {
        let (confirmed, _) = engine.step(chunk)
        if confirmed.hasPrefix(lastConfirmed), confirmed.count > lastConfirmed.count {
            let delta = confirmed.suffix(confirmed.count - lastConfirmed.count)
            FileHandle.standardError.write(Data(delta.utf8))
        }
        lastConfirmed = confirmed
    }

    private func endRecording() {
        guard state == .recording else { return }
        state = .transcribing
        let micRef = mic
        mic = MicCapture()                               // fresh engine for the next gesture
        // Drain + flush off the main thread so a slow finish never freezes the UI.
        Task.detached(priority: .userInitiated) { [engine] in
            _ = micRef.stop()                            // flushes the trailing chunk
            let final = engine.finish()
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
