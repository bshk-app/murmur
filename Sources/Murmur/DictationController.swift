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
    // Not private: tests assert on the HUD the controller drives - notably
    // that the language badge follows a target changed mid-talk - which is
    // otherwise only observable by looking at the screen.
    let hud = HUDController()
    /// Keeps translation models resident between utterances. Built eagerly and
    /// cheaply: nothing loads until a target language is set and something is
    /// actually translated.
    private let translation = TranslationService(modelsRoot: TranslationModels.root)
    /// Captions translate continuously rather than once at stop, so they keep
    /// their own phrase cache on top of the shared engine.
    @ObservationIgnored
    // Not `private`: a test swaps in a fake `PhraseTranslating` to control
    // translation timing deterministically, without 17 MB of models on disk.
    lazy var captionTranslation = CaptionTranslator(service: translation)
    // Not `private`: a test awaits this to know a translation pass settled.
    @ObservationIgnored var captionTranslateTask: Task<Void, Never>?
    /// The in-flight `CaptionTranslator.reset()`, if one has not yet finished.
    /// Spawning it as a bare `Task { await ... }` and moving on would only
    /// make the clear *probably* land before the next snapshot's translate
    /// call reaches the same actor - a new caption session gets a brand new
    /// `CaptionEngine` (see `TwoTierEngine.makeCaptionEngine`), whose segment
    /// ids restart at 1, so the very next talk's first segment can collide
    /// with the previous talk's under `CaptionTranslator`'s id/text cache and
    /// come back in the old language pair if the clear has not actually run
    /// yet. Tracking the handle lets `translateCaptions` await it explicitly
    /// - a real happens-before, not a hopeful ordering.
    // Not `private`: a test drives this directly to prove translateCaptions
    // actually awaits it rather than merely hoping it finished in time.
    @ObservationIgnored var captionTranslationReset: Task<Void, Never>?
    /// The language captions were started with, and the target last translated
    /// into. Both belong to the session, not to the current setting. Not
    /// `private`: tests drive `translateCaptions` directly without the mic
    /// session `beginCaptions()` would otherwise require.
    @ObservationIgnored var captionSource: String?
    @ObservationIgnored var captionTarget: String?
    /// Bumped whenever a caption session starts or stops, and - see the
    /// comment inside `translateCaptions` - on every snapshot too.
    ///
    /// `cancel()` alone cannot make a late translation safe: the work inside is
    /// a synchronous C++ call that runs to completion regardless, so a pass
    /// already in the engine when the talk ends will still come back holding a
    /// finished line. Stamping it and checking the stamp at the moment of
    /// writing is what keeps the previous talk's translation from landing under
    /// the next one's text.
    @ObservationIgnored private(set) var captionGeneration: UInt64 = 0

    /// Whether a caption translation started under `token` may still be shown.
    func captionTranslationIsCurrent(_ token: UInt64) -> Bool {
        token == captionGeneration
    }

    /// Retire every in-flight caption translation.
    ///
    /// The bump is what does the work. `cancel()` is a courtesy: the pass may
    /// already be inside a synchronous C++ translate that runs to completion no
    /// matter what, and it is the stamp check at the write that stops its
    /// result from landing under the next talk's text.
    func retireCaptionTranslations() {
        captionTranslateTask?.cancel()
        captionTranslateTask = nil
        captionGeneration &+= 1
        captionSource = nil
        captionTarget = nil
    }
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

    /// Everything `bootstrap` performs, as data.
    ///
    /// Declarative because the failure being guarded against is an *omission*,
    /// and an omission inside a function body is invisible to any test that
    /// cannot run that body. `bootstrap` registers Carbon hotkeys, prompts for
    /// the microphone and loads multi-gigabyte models — none of which belongs
    /// in a unit test. A list can be inspected without being executed.
    enum StartupStep: CaseIterable {
        case transcriptEcho
        case captionEcho
        case hotkeys
        case microphonePermission
        case currentMode
        /// Resume an interrupted or never-started model fetch. Without this, a
        /// target chosen in a previous run whose download did not finish would
        /// never resume: the only trigger is the picker changing, and
        /// reopening the app does not change it. The user would dictate and
        /// quietly get untranslated text.
        case translationModels
    }

    /// The steps actually run, kept separate from `allCases` on purpose: the
    /// pair makes "declared but never performed" a detectable state rather
    /// than a silent gap, which is exactly how translation preparation went
    /// missing at launch in the first place.
    static let startupSteps: [StartupStep] = [
        .transcriptEcho,
        .captionEcho,
        .hotkeys,
        .microphonePermission,
        .currentMode,
        .translationModels,
    ]

    func bootstrap() {
        for step in Self.startupSteps { apply(step) }
    }

    private func apply(_ step: StartupStep) {
        switch step {
        case .transcriptEcho:
            session.onUpdate = { [weak self] confirmed, partial in self?.echo(confirmed, partial) }
        case .captionEcho:
            captionSession.onSnapshot = { [weak self] snapshot in self?.echoCaptions(snapshot) }
        case .hotkeys:
            KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.hotkeyDown(submit: false) }
            KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.hotkeyUp() }
            KeyboardShortcuts.onKeyDown(for: .dictateAndSend) { [weak self] in self?.hotkeyDown(submit: true) }
            KeyboardShortcuts.onKeyUp(for: .dictateAndSend) { [weak self] in self?.hotkeyUp() }
        case .microphonePermission:
            session.requestMicrophonePermission()   // surface the mic prompt early
        case .currentMode:
            prepareCurrentMode()                    // load only what this mode needs
        case .translationModels:
            prepareTranslation()                    // returns at once when present
        }
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

    // MARK: quality translation model

    /// In-flight quality-model fetches, keyed by direction. A dictionary, not
    /// a single slot: the fast tier's download engine already lets ru-en and
    /// en-ru fetch concurrently (its dedup key is the install directory, which
    /// differs per pair), and a single flat `Task?`/`TranslationDownload?`
    /// here would either misattribute one pair's progress bar to whichever
    /// pair the picker happens to show, or silently refuse a second
    /// direction's tap while the first is still running - both worse than the
    /// two or three dictionary entries this ever actually holds.
    @ObservationIgnored private var qualityDownloadTasks: [LanguagePair: Task<Void, Never>] = [:]
    @ObservationIgnored private var qualityDownloadGenerations: [LanguagePair: Int] = [:]
    /// Observed by the popover to draw the quality download bar for the pair
    /// it is currently showing.
    private var qualityDownloads: [LanguagePair: TranslationDownload] = [:]
    /// Set on failure, cleared on the next attempt for that pair. A settings
    /// screen showing nothing after a tap reads as broken, not as "nothing
    /// happened".
    private var qualityDownloadErrors: [LanguagePair: String] = [:]

    func qualityDownload(for pair: LanguagePair) -> TranslationDownload? {
        qualityDownloads[pair]
    }

    func qualityDownloadError(for pair: LanguagePair) -> String? {
        qualityDownloadErrors[pair]
    }

    /// The direct pair the quality control acts on right now, or nil when
    /// there is nothing to offer: automatic detection has no source, no
    /// target is chosen, or the pair only routes through a pivot. The quality
    /// tier has no converted pivot leg yet, so a button that always failed
    /// would be worse than no button.
    var qualityCandidatePair: LanguagePair? {
        guard let target = TranslationSetting.target else { return nil }
        let source = SpeechLanguage.current
        guard source != SpeechLanguage.automatic,
              case let .direct(pair)? = LanguagePair.route(from: source, to: target)
        else { return nil }
        return pair
    }

    /// Whether MurmurKit has a CTranslate2 conversion for this pair at all,
    /// regardless of whether it is installed yet. Most directions do not -
    /// only ru-en and en-ru are converted so far - and the control should not
    /// appear for those rather than offer a download that can only fail.
    func qualityModelIsOffered(for pair: LanguagePair) -> Bool {
        TranslationDownloader.expectedDownloadBytes(for: pair, kind: .quality) != nil
    }

    func qualityModelIsInstalled(for pair: LanguagePair) -> Bool {
        TranslationDownloader.isInstalled(pair: pair, in: TranslationModels.root, kind: .quality)
    }

    /// Start (or ignore a repeat tap on) the quality-model download for `pair`.
    /// A different pair already downloading is untouched and keeps running.
    ///
    /// Guarded on the task itself, not on `qualityDownloads[pair]` being nil:
    /// the bar briefly reads nil between the first byte's callback landing and
    /// the task actually starting, and a second tap in that gap must still be
    /// a no-op rather than a second fetch of the same 250 MB.
    func downloadQualityModel(for pair: LanguagePair) {
        guard qualityDownloadTasks[pair] == nil else { return }
        guard !qualityModelIsInstalled(for: pair) else { return }
        let generation = (qualityDownloadGenerations[pair] ?? 0) &+ 1
        qualityDownloadGenerations[pair] = generation
        qualityDownloadErrors[pair] = nil
        let root = TranslationModels.root
        qualityDownloadTasks[pair] = Task.detached(priority: .utility) { [weak self] in
            do {
                _ = try await TranslationDownloader.download(
                    pair: pair, into: root, kind: .quality,
                    onProgress: { progress in
                        guard let self, self.qualityDownloadGenerations[pair] == generation else { return }
                        self.qualityDownloads[pair] = TranslationDownload(
                            fraction: progress.fraction,
                            receivedBytes: progress.receivedBytes,
                            totalBytes: progress.totalBytes)
                    })
                await MainActor.run { [weak self] in
                    guard let self, self.qualityDownloadGenerations[pair] == generation else { return }
                    self.qualityDownloads[pair] = nil
                    self.qualityDownloadTasks[pair] = nil
                }
                PostHogSDK.shared.capture("quality_model_downloaded", properties: [
                    "pair": pair.description,
                ])
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.qualityDownloadGenerations[pair] == generation else { return }
                    self.qualityDownloads[pair] = nil
                    self.qualityDownloadTasks[pair] = nil
                    self.qualityDownloadErrors[pair] = Self.qualityErrorMessage(error)
                }
                PostHogSDK.shared.capture("quality_model_download_failed", properties: [
                    "pair": pair.description,
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    /// `TranslationDownloader.Err` has no `CustomStringConvertible` - it is
    /// meant for callers to match on, not to show - so a raw
    /// `localizedDescription` here would read as "the operation couldn't be
    /// completed" with no useful detail. Network errors (`URLError` etc.) go
    /// through untouched: their `localizedDescription` already says the real
    /// thing ("The Internet connection appears to be offline").
    private static func qualityErrorMessage(_ error: Error) -> String {
        guard let err = error as? TranslationDownloader.Err else {
            return error.localizedDescription
        }
        switch err {
        case .insufficientSpace:
            return "Not enough disk space for the quality model."
        case .httpStatus, .digestMismatch, .notGzip, .inflateFailed:
            return "Download failed \u{2014} try again."
        case .unpinnedDirection:
            return "No quality model exists for this language pair."
        case .qualityDownloadBusy:
            return "Another quality model is downloading \u{2014} try again once it finishes."
        }
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
            hud.begin(lang: SpeechLanguage.badge(for: language),
                      target: TranslationSetting.badge(dictating: language),
                      interactive: toggle, submits: submit,
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
            // Pinned for the whole talk, exactly as the dictation path pins it
            // at stop. The Language picker stays live while captions run, and
            // the recogniser keeps the language it was started with — reading
            // the setting again per snapshot would hand already-transcribed
            // Russian to the engine as, say, German and produce confident
            // nonsense rather than an obvious failure.
            captionGeneration &+= 1
            captionSource = language
            captionTarget = TranslationSetting.target
            // A new talk must not inherit the previous one's phrases.
            captionTranslationReset = Task { [captionTranslation] in await captionTranslation.reset() }
            latchedToggle = true    // captions is always tap-on / tap-off
            state = .recording
            PostHogSDK.shared.capture("captions_started", properties: ["language": language])
            hud.begin(lang: SpeechLanguage.badge(for: language),
                      target: TranslationSetting.badge(dictating: language),
                      interactive: true, submits: false,
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
        Task { @MainActor in self.translateCaptions(snapshot) }
    }

    /// Keep the HUD's second line in step with the closed phrases.
    ///
    /// Coalesced rather than queued: snapshots arrive several times a second
    /// and only the newest matters, so a still-running pass is replaced instead
    /// of another being stacked behind it. Cheap in the common case because the
    /// translator only works on phrases whose text it has not already seen.
    /// Not `private`: tests drive this directly, without a live mic session.
    func translateCaptions(_ snapshot: CaptionSnapshot) {
        // Before the guard, so it covers both outcomes with one rule: the
        // header badge tracks the *live* setting rather than the one `begin`
        // captured. The picker stays enabled during a talk, so the target can
        // change under us (handled below) or be switched off entirely (the
        // guard's else) - and in both cases a stale `RU → EN` would be
        // advertising a second line that is now German, or gone.
        // `badge(dictating:)` is the same gate the initial stamp used, so the
        // two can never disagree.
        hud.setTranslationTarget(captionSource.map(TranslationSetting.badge(dictating:)) ?? "")
        guard let source = captionSource,
              let target = TranslationSetting.target,
              TranslationSetting.canTranslate(from: source) else {
            captionTranslateTask?.cancel()
            // See the bump below: an abandoned pass from before translation
            // turned off can still land afterward and overwrite this
            // intentional blank with stale, now-unwanted text.
            captionGeneration &+= 1
            hud.showTranslation("")
            return
        }
        // Switching target mid-talk re-translates everything: a second line
        // holding half German and half French would be worse than a pause.
        if captionTarget != target {
            captionTarget = target
            captionTranslateTask?.cancel()
            captionTranslationReset = Task { [captionTranslation] in await captionTranslation.reset() }
        }
        captionTranslateTask?.cancel()
        // Stamped fresh for *this* snapshot, not only at session boundaries.
        // `cancel()` is a courtesy: the pass may already be inside the
        // synchronous, non-cancellable C++ translate (see the doc on
        // `captionGeneration`), so an older snapshot's task can still finish
        // - and write - after a newer one already has. Session-level
        // stamping alone only rejects a translation from an already-ended
        // talk; within the same talk it does nothing, because every snapshot
        // shared one generation. That let a slower, stale pass silently
        // clobber the HUD with a shorter, already-superseded line, with no
        // further snapshot to correct it if the speaker then paused. Bumping
        // here makes every snapshot's generation unique, so only the result
        // whose generation still matches - the most recently *started* pass,
        // whichever finishes first - is ever allowed to write.
        captionGeneration &+= 1
        let generation = captionGeneration
        // Waited on explicitly, not assumed already finished: a bare
        // `Task { await reset() }` only *probably* reaches the actor before
        // this call does, and a stale hit in `CaptionTranslator`'s cache
        // would read as a normal cache hit - correct id, correct text, wrong
        // language - with nothing downstream able to tell the difference.
        let pendingReset = captionTranslationReset
        captionTranslateTask = Task { [captionTranslation, hud, weak self] in
            await pendingReset?.value
            let line = await captionTranslation.translation(
                of: snapshot.confirmed, draft: snapshot.provisional,
                from: source, to: target)
            await MainActor.run {
                // Checked here rather than before the hop: the session can end
                // while this pass is inside the engine, and only the stamp
                // taken at the write can tell whether the HUD on screen is
                // still the one this line belongs to.
                guard let self, self.captionTranslationIsCurrent(generation) else { return }
                hud.showTranslation(line)
            }
        }
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
            var translatedWithQuality = false
            // Nothing to route from under automatic detection, so do not even
            // show the translating state for a pass that cannot produce one.
            if let targetAtStop, !final.isEmpty,
               TranslationSetting.canTranslate(from: sourceAtStop) {
                await MainActor.run { self.hud.translating() }
                // The quality engine, not the realtime one: this is the one
                // paste per utterance, not a live draft redrawn several times a
                // second, so the ~350 ms CTranslate2 costs is the right trade
                // for the reason the whole second engine exists. A direction
                // with no quality model installed falls back to the fast one
                // inside translateBest itself, at no extra cost.
                let outcome = await translation.translateBestOrEmpty(
                    final, from: sourceAtStop, to: targetAtStop)
                translated = outcome.text
                translatedWithQuality = outcome.usedQuality
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
                self.hud.finish(final, delivery: delivery, translation: translated,
                                translationIsQuality: translatedWithQuality)
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
        // Retire any pass still running: `finish` is about to clear the second
        // line, and a late write must not put it back.
        retireCaptionTranslations()
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
