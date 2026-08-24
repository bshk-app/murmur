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

    private let session: DictationSession
    private let captionSession: CaptionSession
    private let hud = HUDController()

    /// Both pipelines share one model stack — switching between Dictation and
    /// Captions in the popover must not load a second ~3.4 GB copy of the weights,
    /// nor set a second Metal memory cap.
    init() {
        let models = SpeechModels()
        self.session = DictationSession(models: models)
        self.captionSession = CaptionSession(models: models)
    }

    /// The shared, already-warmed pipeline — exposed so onboarding's try-it step
    /// reuses it instead of spinning up a second `DictationSession`.
    var dictationSession: DictationSession { session }

    @ObservationIgnored private var promptedAccessibility = false
    @ObservationIgnored private var isPreparing = false

    /// Which pipeline owns the live session, and whether its stop comes from a
    /// second tap rather than the key release. Both latched at start so a mode
    /// change mid-session cannot strand a running mic.
    @ObservationIgnored private var captionsRunning = false
    @ObservationIgnored private var latchedToggle = false

    /// Whether this utterance ends with a Return. Latched when recording begins and
    /// left alone until it ends: in hold mode there is no separate stop gesture to
    /// carry the intent, so letting the *stopping* key decide would make the two
    /// trigger modes behave differently for the same pair of shortcuts.
    @ObservationIgnored private var submitOnFinish = false

    private(set) var microphones: [MicrophoneDevice] = []

    /// Refresh when the popover opens. Core Audio device IDs are transient, so the
    /// UI stores UIDs and rebuilds the current catalog each time it is shown.
    /// Returns the selection the Picker should display; a missing device visibly
    /// falls back to System Default.
    @discardableResult
    func refreshMicrophones(preferredUID: String) -> String {
        microphones = AudioInputDevices.available()
        return AudioInputDevices.sanitizedUID(preferredUID, devices: microphones)
    }

    var shortcutLabel: String {
        KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "⌃⌥Space"
    }

    var supportedLanguageCodes: [String] { dictationSession.supportedLanguageCodes }

    /// The binding actually held for this utterance, so the HUD names the key the
    /// user is on rather than a guess. An unbound send-shortcut falls back to the
    /// plain one — `shortcutLabel` already carries the last-resort default.
    private func activeShortcutLabel(submit: Bool) -> String {
        guard submit else { return shortcutLabel }
        return KeyboardShortcuts.getShortcut(for: .dictateAndSend)?.description ?? shortcutLabel
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

    var mascotMood: DictatorMascotMood {
        switch state {
        case .recording: return .listening
        case .transcribing: return .transcribing
        case .error: return .error
        case .loadingModels, .idle, .transcribed: return .idle
        }
    }

    func bootstrap() {
        session.onUpdate = { [weak self] confirmed, partial in self?.echo(confirmed, partial) }
        captionSession.onSnapshot = { [weak self] snapshot in self?.echoCaptions(snapshot) }
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.hotkeyDown(submit: false) }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.hotkeyUp() }
        KeyboardShortcuts.onKeyDown(for: .dictateAndSend) { [weak self] in self?.hotkeyDown(submit: true) }
        KeyboardShortcuts.onKeyUp(for: .dictateAndSend) { [weak self] in self?.hotkeyUp() }
        session.requestMicrophonePermission()            // surface the mic prompt early
        prepareCurrentMode()                             // load only what this mode needs
    }

    func requestAccessibility() { Accessibility.prompt() }

    /// Re-load when the Model or App-mode setting changes (popover) — pulls in the
    /// newly selected mode's models so the next press starts instantly.
    ///
    /// Never while a session is live: preparation moves `state` to `.loadingModels`,
    /// which would strand the running mic (stop only fires from `.recording`).
    func prepareCurrentMode() {
        guard !isActive else { return }
        if AppMode.current == .captions { return prepareCaptions() }
        prepare(mode: ModelSetting.current)
    }

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

    /// Hotkey press: a running session keeps the trigger it started with even if
    /// Settings change underneath it.
    private func hotkeyDown(submit: Bool) {
        RecordingTriggerPolicy.route(
            .keyDown,
            state: recordingTriggerState,
            begin: { beginRecording(submit: submit) },
            end: endRecording
        )
    }

    /// Captions is always tap-on / tap-off, whatever the hotkey setting says —
    /// holding a key through a talk is not a thing anyone can do.
    private static var togglesOnPress: Bool {
        AppMode.current == .captions || TriggerMode.current == .toggle
    }

    private var recordingTriggerState: RecordingTriggerState {
        RecordingTriggerState(
            isRecording: state == .recording,
            isActive: isActive,
            latchedToggle: latchedToggle,
            isEnabled: DictationEnabled.value
        )
    }

    /// Hotkey release only ends dictation in hold mode (toggle ignores release).
    private func hotkeyUp() {
        RecordingTriggerPolicy.route(
            .keyUp,
            state: recordingTriggerState,
            begin: {},
            end: endRecording
        )
    }

    private func beginRecording(submit: Bool) {
        guard state != .recording, state != .transcribing else { return }
        if AppMode.current == .captions { return beginCaptions() }
        let modelMode = ModelSetting.current
        // Models for this mode not loaded yet (e.g. just switched) — kick the load
        // and skip this press; the next one records once ready.
        guard session.isReady(modelMode) else { prepare(mode: modelMode); return }
        let language = SpeechLanguage.current
        let toggle = Self.togglesOnPress
        submitOnFinish = submit
        do {
            // The live two-tier view stays in the HUD; the field receives one paste
            // on release (Variant B — paste is atomic, so no live-into-field typing).
            try session.start(
                mode: modelMode,
                language: language,
                microphoneUID: MicrophoneSetting.currentUID
            )
            captionsRunning = false
            latchedToggle = toggle
            state = .recording
            PostHogSDK.shared.capture("dictation_started", properties: [
                "model_mode": modelMode.rawValue,
                "trigger_mode": TriggerMode.current.rawValue,
                "insert_mode": Self.insertModeAnalyticsValue,
                "language": language,
            ])
            // Toggle mode → interactive HUD with a Stop button (tap-to-stop too).
            hud.begin(lang: SpeechLanguage.badge(for: language), interactive: toggle, submits: submit,
                      shortcutLabel: activeShortcutLabel(submit: submit),
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

    /// Captions run for a whole talk: one live epoch per phrase, each corrected by
    /// the batch model while the speaker carries on, and nothing is ever typed.
    private func beginCaptions() {
        guard captionSession.isReady() else { return prepareCaptions() }
        let language = SpeechLanguage.current
        submitOnFinish = false
        do {
            try captionSession.start(
                language: language,
                microphoneUID: MicrophoneSetting.currentUID
            )
            captionsRunning = true
            latchedToggle = true    // captions is always tap-on / tap-off
            state = .recording
            PostHogSDK.shared.capture("captions_started", properties: ["language": language])
            hud.begin(lang: SpeechLanguage.badge(for: language), interactive: true, submits: false,
                      shortcutLabel: activeShortcutLabel(submit: false),
                      onStop: { [weak self] in self?.endRecording() })
        } catch {
            state = .error(error.localizedDescription)
            hud.error("Open Privacy in Settings →")
        }
    }

    /// Captions need the boundary detector on top of the dictation models, so its
    /// readiness is loaded separately — but off the same weights.
    private func prepareCaptions() {
        guard !isPreparing else { return }
        guard !captionSession.isReady() else {
            if case .loadingModels = state { state = .idle }
            return
        }
        isPreparing = true
        state = .loadingModels
        Task { @MainActor in
            defer { isPreparing = false }
            do {
                try await captionSession.load()
                if case .loadingModels = state { state = .idle }
            } catch {
                state = .error("model load: \(error.localizedDescription)")
            }
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

    /// Same job as `echo`, from the caption pipeline's rolling snapshot: the
    /// confirmed phrases read as one paragraph, with the live draft as the tail.
    /// The HUD clamps to its own capacity, keeping the most recent words.
    private nonisolated func echoCaptions(_ snapshot: CaptionSnapshot) {
        let confirmed = snapshot.confirmed.map(\.text).joined(separator: " ")
        echo(confirmed, snapshot.provisional)
    }

    private func endRecording() {
        guard state == .recording else { return }
        state = .transcribing
        if captionsRunning { return endCaptions() }
        let modelModeAtStop = ModelSetting.current.rawValue
        let submitAtStop = submitOnFinish
        // Drain off the main thread so a slow finish never freezes the UI, then
        // paste the final on the main thread (pasteboard + ⌘V).
        Task.detached(priority: .userInitiated) { [session] in
            let final = session.stop()
            await MainActor.run { [weak self] in
                guard let self else { return }
                FileHandle.standardError.write(Data("\n".utf8))
                self.hud.finish(final, linger: 1.0)
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

    /// Stop captions: close the open phrase, hold the last line on screen long
    /// enough to finish reading it, and type nothing anywhere.
    private func endCaptions() {
        Task.detached(priority: .userInitiated) { [captionSession] in
            let snapshot = captionSession.stop()
            await MainActor.run { [weak self] in
                guard let self else { return }
                FileHandle.standardError.write(Data("\n".utf8))
                let text = (snapshot?.confirmed.map(\.text) ?? []).joined(separator: " ")
                self.hud.finish(text, linger: 4.0)
                PostHogSDK.shared.capture("captions_completed", properties: [
                    "phrase_count": snapshot?.confirmed.count ?? 0,
                    "character_count": text.count,
                ])
                self.state = .transcribed(text)
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
