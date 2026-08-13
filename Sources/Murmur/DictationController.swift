import AppKit
import Foundation
import KeyboardShortcuts
import MurmurKit
import Observation
import PostHog

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

    /// Pinned since the Insert-mode setting was removed. Kept in the events rather
    /// than dropped so historical PostHog series stay continuous.
    private static let insertModeAnalyticsValue = "inField"

    private let session = DictationSession()
    private let hud = HUDController()

    /// The shared, already-warmed pipeline — exposed so onboarding's try-it step
    /// reuses it instead of spinning up a second `DictationSession`.
    var dictationSession: DictationSession { session }
    @ObservationIgnored private var promptedAccessibility = false
    @ObservationIgnored private var isPreparing = false

    /// Whether this utterance ends with a Return. Latched when recording begins and
    /// left alone until it ends: in hold mode there is no separate stop gesture to
    /// carry the intent, so letting the *stopping* key decide would make the two
    /// trigger modes behave differently for the same pair of shortcuts.
    @ObservationIgnored private var submitOnFinish = false

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
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.hotkeyDown(submit: false) }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.hotkeyUp() }
        KeyboardShortcuts.onKeyDown(for: .dictateAndSend) { [weak self] in self?.hotkeyDown(submit: true) }
        KeyboardShortcuts.onKeyUp(for: .dictateAndSend) { [weak self] in self?.hotkeyUp() }
        session.requestMicrophonePermission()            // surface the mic prompt early
        prepare(mode: ModelSetting.current)              // load only the current mode's models
    }

    func requestAccessibility() { Accessibility.prompt() }

    /// Re-load when the Model setting changes (popover) — pulls in the newly
    /// selected mode's models so the next dictation starts instantly.
    func prepareCurrentMode() { prepare(mode: ModelSetting.current) }

    /// Lazily load (download on first run) only the models `mode` needs, surfacing
    /// a loading state. A no-op when already ready or a load is in flight.
    private func prepare(mode: DictationMode) {
        guard !isPreparing else { return }
        guard !session.isReady(mode) else {
            // Already warmed (e.g. the onboarding Download step loaded both models
            // into the shared session before bootstrap ran) — just go idle.
            if case .loadingModels = state { state = .idle }
            return
        }
        isPreparing = true
        state = .loadingModels
        Task { @MainActor in
            defer { isPreparing = false }
            do {
                try await session.load(mode: mode)
                if case .loadingModels = state { state = .idle }
            } catch {
                state = .error("model load: \(error.localizedDescription)")
            }
        }
    }

    /// Hotkey press: hold-mode starts; toggle-mode flips start/stop. Gated by the
    /// master enable.
    private func hotkeyDown(submit: Bool) {
        guard DictationEnabled.value else { return }
        switch TriggerMode.current {
        case .hold:   beginRecording(submit: submit)
        case .toggle: if state == .recording { endRecording() } else { beginRecording(submit: submit) }
        }
    }

    /// Hotkey release only ends dictation in hold mode (toggle ignores release).
    private func hotkeyUp() {
        if TriggerMode.current == .hold { endRecording() }
    }

    private func beginRecording(submit: Bool) {
        guard state != .recording, state != .transcribing else { return }
        let modelMode = ModelSetting.current
        // Models for this mode not loaded yet (e.g. just switched) — kick the load
        // and skip this press; the next one records once ready.
        guard session.isReady(modelMode) else { prepare(mode: modelMode); return }
        let toggle = TriggerMode.current == .toggle
        submitOnFinish = submit
        do {
            // The live two-tier view stays in the HUD; the field receives one paste
            // on release (Variant B — paste is atomic, so no live-into-field typing).
            try session.start(mode: modelMode)
            state = .recording
            PostHogSDK.shared.capture("dictation_started", properties: [
                "model_mode": modelMode.rawValue,
                "trigger_mode": TriggerMode.current.rawValue,
                "insert_mode": Self.insertModeAnalyticsValue,
            ])
            // Toggle mode → interactive HUD with a Stop button (tap-to-stop too).
            hud.begin(lang: "Auto", interactive: toggle, submits: submit,
                      onStop: { [weak self] in self?.endRecording() })
        } catch {
            state = .error(error.localizedDescription)
            PostHogSDK.shared.capture("dictation_failed", properties: [
                "error": error.localizedDescription,
                "model_mode": modelMode.rawValue,
            ])
            hud.error("Open Privacy in Settings →")
        }
    }

    /// Runs on the mic capture queue (via `onUpdate`). Two jobs (nothing is typed
    /// into the field live — the field gets one paste on release):
    ///  1. drive the HUD overlay (confirmed prefix + the fast Nemotron `⟨tail⟩`),
    ///     hopping to the main actor since the panel is UI;
    ///  2. echo the same view to the console, redrawn in place — handy from Xcode.
    private nonisolated func echo(_ confirmed: String, _ partial: String) {
        Task { @MainActor in self.hud.update(confirmed: confirmed, partial: partial) }
        #if DEBUG
        let line = partial.isEmpty ? confirmed : "\(confirmed) ⟨\(partial)⟩"
        let tail = line.count > 100 ? "…" + String(line.suffix(100)) : line
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(tail)".utf8))
        #endif
    }

    private func endRecording() {
        guard state == .recording else { return }
        state = .transcribing
        let modelModeAtStop = ModelSetting.current.rawValue
        let submitAtStop = submitOnFinish
        // Drain off the main thread so a slow finish never freezes the UI, then
        // paste the final on the main thread (pasteboard + ⌘V).
        Task.detached(priority: .userInitiated) { [session] in
            let final = session.stop()
            await MainActor.run { [weak self] in
                guard let self else { return }
                FileHandle.standardError.write(Data("\n".utf8))
                self.hud.finish(final)               // show the final, then fade
                if !final.isEmpty { self.insertFinal(final, submit: submitAtStop) }
                PostHogSDK.shared.capture("dictation_completed", properties: [
                    "word_count": final.split(separator: " ").count,
                    "character_count": final.count,
                    "is_empty": final.isEmpty,
                    "model_mode": modelModeAtStop,
                    "insert_mode": Self.insertModeAnalyticsValue,
                    "submit_on_finish": submitAtStop,
                ])
                self.state = .transcribed(final)
            }
        }
    }

    /// Paste the final transcript into the focused field. Posting ⌘V needs
    /// Accessibility — if untrusted, prompt once and leave the text on the clipboard
    /// so it's not lost. Secure input (password fields) blocks paste; we say so in
    /// the HUD instead of dropping silently.
    ///
    /// Neither of those two paths can submit: Return is posted only on the branch of
    /// `TextInjector.paste` that actually pressed ⌘V. Sending an empty message
    /// because the text never landed is the worst thing this feature could do, so
    /// that invariant is structural rather than a condition someone must remember.
    private func insertFinal(_ text: String, submit: Bool) {
        guard Accessibility.isTrusted else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(TextInjector.payload(text, submit: submit), forType: .string)
            if !promptedAccessibility { promptedAccessibility = true; Accessibility.prompt() }
            return
        }
        switch TextInjector.paste(text, submit: submit) {
        case .pasted, .failed:
            break
        case .copiedSecureInput:
            hud.error(String(localized: "Field is protected — press ⌘V"))
        }
    }
}
