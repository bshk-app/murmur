import AppKit
import Observation

/// Wires the global hotkey to mic capture and exposes a human-readable status
/// for the menu bar.
///
/// Step A: no STT yet — on release we report what we captured (duration + peak
/// level), which proves the permission grants (Accessibility + Microphone) and
/// the 16 kHz audio path before the heavy MLX integration lands.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case needsAccessibility
        case recording
        case captured(durationS: Double, peakRMS: Float)
        case error(String)
    }

    private(set) var state: State = .idle

    private let hotkey = HotkeyMonitor()
    private var mic = MicCapture()

    var statusLine: String {
        switch state {
        case .idle: return "Idle — hold ⌃⌥Space"
        case .needsAccessibility: return "Grant Accessibility to enable the hotkey"
        case .recording: return "Recording…"
        case let .captured(d, rms): return String(format: "Captured %.1fs · peak %.3f", d, rms)
        case let .error(m): return "Error: \(m)"
        }
    }

    func bootstrap() {
        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.endRecording() }
        MicCapture.requestPermission { _ in }            // surface the mic prompt early
        enableHotkey()
    }

    /// Try to arm the hotkey tap; if not yet trusted, prompt and poll until it is.
    func enableHotkey() {
        if hotkey.start() {
            if state == .needsAccessibility { state = .idle }
            return
        }
        state = .needsAccessibility
        Accessibility.prompt()
        Task { @MainActor in
            for _ in 0 ..< 120 {                          // ~60 s of 500 ms polls
                try? await Task.sleep(for: .milliseconds(500))
                if hotkey.start() { state = .idle; return }
            }
        }
    }

    private func beginRecording() {
        guard state != .recording else { return }
        do {
            try mic.start()
            state = .recording
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        let r = mic.stop()
        mic = MicCapture()                                // fresh engine for the next gesture
        state = .captured(durationS: r.durationS, peakRMS: r.peakRMS)
    }
}
