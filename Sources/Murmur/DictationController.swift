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
    /// Keeps translation models resident between utterances. Built eagerly and
    /// cheaply: nothing loads until a target language is set and something is
    /// actually translated.
    private let translation = TranslationService(modelsRoot: TranslationModels.root)
    /// The in-flight model fetch, so scrubbing through the picker cannot leave
    /// a queue of downloads for languages nobody chose.
    @ObservationIgnored private var translationPrepare: Task<Void, Never>?
    /// Observed by the popover to draw the download bar.
    private(set) var translationDownload: TranslationDownload?
    /// Stamps each preparation so a cancelled one cannot repaint or clear the
    /// bar that now belongs to a later choice.
    @ObservationIgnored private var translationGeneration = 0

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

    /// Fetch the translation models for the current pair if they are missing.
    ///
    /// Called when the target language changes rather than at stop: the files
    /// are ~20 MB and pulling them between the stop gesture and the paste would
    /// stall the one moment the user is waiting on. Failure is silent here — an
    /// utterance that finds no model still pastes its original text, and a
    /// download error at picker time is not something to interrupt anyone with.
    func prepareTranslation() {
        // A picker is easy to scrub through; each pass would otherwise start a
        // fetch that nothing stops.
        translationPrepare?.cancel()
        translationDownload = nil
        // Cancellation is not instant: the outgoing task may already have
        // progress callbacks queued for the main actor, and it still has its
        // own tidy-up to run. Both would land on a bar that now belongs to a
        // different language, so every write is stamped and stale ones are
        // dropped rather than raced against.
        translationGeneration &+= 1
        let generation = translationGeneration

        let source = SpeechLanguage.current
        guard let target = TranslationSetting.target,
              source != SpeechLanguage.automatic,
              let route = LanguagePair.route(from: source, to: target) else { return }
        let legs: [LanguagePair]
        switch route {
        case .direct(let pair): legs = [pair]
        case .pivot(let first, let second): legs = [first, second]
        }
        let root = TranslationModels.root

        // Only what is actually missing. An installed leg contributes no bytes
        // and must not inflate the total, or a pivot with one leg already on
        // disk would stall the bar at half.
        let pending = legs.filter { !TranslationDownloader.isInstalled(pair: $0, in: root) }
        guard !pending.isEmpty else { return }

        // Sizes come from the manifest, so the whole pivot is denominated
        // before the first byte moves. Legs are weighted by their real size:
        // 17 MB followed by 43 MB is not two halves.
        let combined = CombinedDownloadProgress(
            legBytes: pending.map { TranslationDownloader.expectedDownloadBytes(for: $0) ?? 0 })

        translationPrepare = Task.detached(priority: .utility) { [weak self] in
            for (index, leg) in pending.enumerated() {
                // Checked between legs so a pivot abandons its second hop.
                if Task.isCancelled { break }
                _ = try? await TranslationDownloader.download(
                    pair: leg, into: root,
                    onProgress: { progress in
                        guard let self, self.translationGeneration == generation else { return }
                        // Weighting lives in `CombinedDownloadProgress` so it
                        // can be tested; doing it here would put the one part
                        // that can silently go wrong out of reach.
                        let point = combined.at(leg: index, received: progress.receivedBytes)
                        self.translationDownload = TranslationDownload(
                            fraction: point.fraction,
                            receivedBytes: point.receivedBytes,
                            totalBytes: combined.totalBytes)
                    })
            }
            await MainActor.run { [weak self] in
                guard let self, self.translationGeneration == generation else { return }
                self.translationDownload = nil
            }
        }
    }

    /// Live translation-model download, or nil when nothing is being fetched.
    ///
    /// Stays nil for an already-installed pair — that path returns before any
    /// byte is requested, so switching to a language already on disk shows no
    /// bar at all rather than flashing one for a frame.
    struct TranslationDownload: Equatable {
        var fraction: Double
        var receivedBytes: Int64
        var totalBytes: Int64
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
        let language = SpeechLanguage.current
        // The routing matrix marks Nemotron's streaming preview unreliable for a
        // few languages, so the live draft is dropped and the batch pass stands
        // alone. Resolved before the readiness check: asking whether the models
        // for Hybrid are loaded is the wrong question when Hybrid will not run.
        let modelMode = ModelSetting.current.effective(for: language)
        // Models for this mode not loaded yet (e.g. just switched) — kick the load
        // and skip this press; the next one records once ready.
        guard session.isReady(modelMode) else { prepare(mode: modelMode); return }
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
        // Read once, at stop: the user could change the target while the batch
        // pass runs, and half of an utterance in one language is worse than all
        // of it in the language they asked for when they started.
        let sourceAtStop = SpeechLanguage.current
        let targetAtStop = TranslationSetting.target
        // The mic is already closed by `stop()`, so the overlay must stop looking
        // like it is listening while the batch pass runs.
        hud.finalizing()
        // Drain off the main thread so a slow finish never freezes the UI, then
        // paste the final on the main thread (pasteboard + ⌘V).
        Task.detached(priority: .userInitiated) { [session, translation] in
            let final = session.stop()

            // Translate off the main thread, between the transcript and the
            // paste: the field receives the translation, and the HUD shows both
            // lines so the speaker can still see what was heard.
            var translated = ""
            // Nothing to route from under automatic detection, so do not even
            // show the translating state for a pass that cannot produce one.
            if let targetAtStop, !final.isEmpty,
               TranslationSetting.canTranslate(from: sourceAtStop) {
                await MainActor.run { self.hud.translating() }
                translated = await translation.translateOrEmpty(
                    final, from: sourceAtStop, to: targetAtStop)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                FileHandle.standardError.write(Data("\n".utf8))
                // What lands in the field is the translation when there is one.
                // Pasting both languages would put text the user never asked
                // for into someone else's document.
                let payload = translated.isEmpty ? final : translated
                let delivery = payload.isEmpty ? TranscriptDelivery.typed
                                               : self.insertFinal(payload, submit: submitAtStop)
                self.hud.finish(final, delivery: delivery, translation: translated)
                PostHogSDK.shared.capture("dictation_completed", properties: [
                    "word_count": final.split(separator: " ").count,
                    "character_count": final.count,
                    "is_empty": final.isEmpty,
                    "model_mode": modelModeAtStop,
                    "insert_mode": Self.insertModeAnalyticsValue,
                    "submit_on_finish": submitAtStop,
                    "delivered": delivery == .typed,
                ])
                self.state = .transcribed(final)
            }
        }
    }

    /// Stop captions: close the open phrase and take the overlay away. The user
    /// asked for it to stop, so holding the last line on screen only keeps it in
    /// front of whatever they turned back to.
    private func endCaptions() {
        hud.finalizing()
        Task.detached(priority: .userInitiated) { [captionSession] in
            let snapshot = captionSession.stop()
            await MainActor.run { [weak self] in
                guard let self else { return }
                FileHandle.standardError.write(Data("\n".utf8))
                let text = (snapshot?.confirmed.map(\.text) ?? []).joined(separator: " ")
                self.hud.finish(text, delivery: .displayedOnly)
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
    private func insertFinal(_ text: String, submit: Bool) -> TranscriptDelivery {
        guard Accessibility.isTrusted else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(TextInjector.payload(text, submit: submit), forType: .string)
            if !promptedAccessibility { promptedAccessibility = true; Accessibility.prompt() }
            return .failed(String(localized: "On the clipboard — grant Accessibility to type"))
        }
        switch TextInjector.paste(text, submit: submit) {
        case .pasted:
            return .typed
        case .failed:
            return .failed(String(localized: "Could not type it — press ⌘V"))
        case .copiedSecureInput:
            return .failed(String(localized: "Field is protected — press ⌘V"))
        }
    }
}
