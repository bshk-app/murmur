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
    private let hud = HUDController()
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

    /// Compact status for the menu popover.
    var shortStatus: String {
        switch state {
        case .loadingModels: return "Loading…"
        case .idle, .transcribed: return "Ready"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case let .error(m): return m
        }
    }

    /// True while a dictation is in flight (drives the popover pulse dot).
    var isActive: Bool {
        state == .recording || state == .transcribing
    }

    func bootstrap() {
        session.onUpdate = { [weak self] confirmed, partial in self?.echo(confirmed, partial) }
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.hotkeyDown() }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.hotkeyUp() }
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

    /// Hotkey press: hold-mode starts; toggle-mode flips start/stop. Gated by the
    /// master enable.
    private func hotkeyDown() {
        guard DictationEnabled.value else { return }
        switch TriggerMode.current {
        case .hold:   beginRecording()
        case .toggle: if state == .recording { endRecording() } else { beginRecording() }
        }
    }

    /// Hotkey release only ends dictation in hold mode (toggle ignores release).
    private func hotkeyUp() {
        if TriggerMode.current == .hold { endRecording() }
    }

    private func beginRecording() {
        guard session.isLoaded, state != .recording, state != .transcribing else { return }
        let mode = InsertMode.current
        let toggle = TriggerMode.current == .toggle
        do {
            // Live-type confirmed words only when inserting into a field AND we can
            // type. In HUD-only (presentation) mode nothing is injected.
            liveInjector.begin(enabled: mode == .inField && Accessibility.isTrusted)
            try session.start()
            state = .recording
            // Toggle mode → interactive HUD with a Stop button (tap-to-stop too).
            hud.begin(presentation: mode == .hudOnly, lang: "Auto",
                      interactive: toggle, onStop: { [weak self] in self?.endRecording() })
        } catch {
            state = .error(error.localizedDescription)
            hud.error("Open Privacy in Settings →")
        }
    }

    /// Runs on the mic capture queue (via `onUpdate`). Three jobs:
    ///  1. live-type newly confirmed (Voxtral) words into the focused field —
    ///     append-only, the volatile `partial` is never injected (model A);
    ///  2. drive the HUD overlay (confirmed prefix + the fast Nemotron `⟨tail⟩`),
    ///     hopping to the main actor since the panel is UI;
    ///  3. echo the same view to the console, redrawn in place — handy from Xcode.
    private nonisolated func echo(_ confirmed: String, _ partial: String) {
        liveInjector.appendConfirmed(confirmed)
        Task { @MainActor in self.hud.update(confirmed: confirmed, partial: partial) }
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
                self.hud.finish(final)               // show the final (lingers in presentation), then fade
                // Only In-field mode types into other apps — that's the only mode
                // that needs Accessibility, so only prompt there.
                if InsertMode.current == .inField, !final.isEmpty,
                   !Accessibility.isTrusted, !self.promptedAccessibility {
                    self.promptedAccessibility = true
                    Accessibility.prompt()
                }
                self.state = .transcribed(final)
            }
        }
    }
}
