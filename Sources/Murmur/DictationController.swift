import AppKit
import Foundation
import Observation

/// Wires the global hotkey + mic capture to the on-device two-tier STT engine
/// and exposes a human-readable status for the menu bar.
///
/// Step B: hold the hotkey → stream mic → live two-tier transcript (Nemotron
/// partials, Voxtral finals). On release the final transcript is shown in the
/// menu and printed to the console. Text injection into the focused field is a
/// later step.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case loadingModels
        case idle
        case needsAccessibility
        case recording
        case transcribed(String)
        case error(String)
    }

    private(set) var state: State = .loadingModels
    let settings = HotkeySettings()

    private let monitor = HotkeyMonitor()
    private var mic = MicCapture()
    private let engine = STTEngine()

    var statusLine: String {
        switch state {
        case .loadingModels: return "Loading models…"
        case .idle: return "Idle — hold \(settings.hotkey.displayString)"
        case .needsAccessibility: return "Grant Accessibility to enable the hotkey"
        case .recording: return "Listening…"
        case let .transcribed(t): return t.isEmpty ? "…(no speech detected)" : t
        case let .error(m): return "Error: \(m)"
        }
    }

    func bootstrap() {
        monitor.onPress = { [weak self] in self?.beginRecording() }
        monitor.onRelease = { [weak self] in self?.endRecording() }
        monitor.update(settings.hotkey)
        settings.onChange = { [weak self] hk in self?.monitor.update(hk) }

        MicCapture.requestPermission { _ in }            // surface the mic prompt early
        enableHotkey()
        loadModels()
    }

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

    /// Try to arm the hotkey tap; if not yet trusted, prompt and poll until it is.
    func enableHotkey() {
        if monitor.start() {
            if state == .needsAccessibility { state = engine.isLoaded ? .idle : .loadingModels }
            return
        }
        state = .needsAccessibility
        Accessibility.prompt()
        Task { @MainActor in
            for _ in 0 ..< 120 {                          // ~60 s of 500 ms polls
                try? await Task.sleep(for: .milliseconds(500))
                if monitor.start() { state = engine.isLoaded ? .idle : .loadingModels; return }
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
        state = .transcribed(final)
    }
}
