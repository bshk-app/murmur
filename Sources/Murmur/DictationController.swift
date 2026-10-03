import AppKit
import AVFoundation
import Foundation
import KeyboardShortcuts
import MurmurKit
import Observation
import PostHog

/// Platform presentation and delivery over the shared iOS/macOS recording session.
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
    private(set) var sessionWarning: String?

    /// Pinned since the Insert-mode setting was removed. Kept in the events rather
    /// than dropped so historical PostHog series stay continuous.
    private static let insertModeAnalyticsValue = "inField"

    var session: any RecordingSessioning
    let hud = HUDController()
    /// Captions render here, not in the HUD — see `CaptionsOverlay`.
    let captionsOverlay = CaptionsOverlay()
    @ObservationIgnored var captionSource: String?
    @ObservationIgnored var captionTarget: String?
    @ObservationIgnored var recordingTask: Task<Void, Never>?
    @ObservationIgnored var captionTranslateTask: Task<Void, Never>?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var stopAfterStart = false
    @ObservationIgnored private var captureFailed = false

    /// The language *this utterance* was recognised in, latched when the
    /// recogniser was started.
    ///
    /// The same pinning captions already do, and for a stronger reason. The
    /// target may be re-read at stop - it is a choice about the output, and
    /// honouring the latest one is a feature. The source is not a choice: it
    /// is a fact about what the recogniser was told, already baked into the
    /// text it produced. Re-reading it at stop meant that changing Language
    /// mid-utterance (easy in toggle mode, where the menu stays reachable)
    /// translated Russian speech as though it were German - a wrong answer
    /// with no error anywhere. Not `private`: tests assert the latch survives
    /// a mid-utterance picker change.
    @ObservationIgnored var dictationSource: String?

    /// What a finished utterance's translation routes *from*.
    ///
    /// The session's latch, never the live picker. One place rather than an
    /// expression at the call site so the rule has somewhere to be stated and
    /// somewhere to be tested. The fallback covers only a stop with no start
    /// behind it, where there is no recognised text to be wrong about.
    var translationSource: String { dictationSource ?? SpeechLanguage.current }

    /// The mode this utterance actually ran in, latched at start.
    ///
    /// Two things go wrong without it, and only one needs a user to do
    /// anything. First, the same staleness as `dictationSource`: switching
    /// Model mid-utterance made the completion event describe a mode that
    /// never ran. Second, and with nobody touching anything -
    /// `beginRecording` runs `ModelSetting.current.effective(for:)`, which
    /// downgrades Fast and Hybrid to Accurate for the languages with no live
    /// draft. `dictation_started` logs that effective mode; reading the raw
    /// setting again at stop meant every Japanese, Korean, Chinese, Arabic
    /// and Vietnamese utterance reported started=accurate and
    /// completed=hybrid. The routing matrix is exactly what these two events
    /// exist to measure, so the one field that says which lane ran cannot be
    /// the field that says which lane was asked for.
    @ObservationIgnored var dictationMode: DictationMode?

    /// The mode a finished utterance is reported as having run in.
    ///
    /// Fallback only covers a stop with no start behind it, where nothing ran
    /// to be described.
    var completedModelMode: DictationMode { dictationMode ?? ModelSetting.current }
    /// The in-flight model fetch, so scrubbing through the picker cannot leave
    /// a queue of downloads for languages nobody chose.
    @ObservationIgnored private var translationPrepare: Task<Void, Never>?
    /// Observed by the popover to draw the download bar.
    private(set) var translationDownload: TranslationDownload?
    /// Stamps each preparation so a cancelled one cannot repaint or clear the
    /// bar that now belongs to a later choice.
    @ObservationIgnored private var translationGeneration = 0

    init(session: (any RecordingSessioning)? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        self.session = session ?? RecordingSession(modelsRoot: root,
            translationRoot: TranslationModels.root, memoryLimit: Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.6))
        connectSession()
    }

    var dictationSession: any RecordingSessioning { session }

    private func connectSession() {
        session.onEvent = { [weak self] event in self?.receive(event) }
    }

    func receive(_ event: RecordingSession.Event) {
        switch event {
        case let .snapshot(snapshot):
            guard state == .recording || state == .transcribing else { return }
            echo(snapshot.confirmed.map(\.text).joined(separator: " "), snapshot.provisional)
        case let .translation(line, _):
            guard captionsRunning, state == .recording else { return }
            captionsOverlay.showTranslation(line)
        case let .preparation(progress):
            if progress.stage == .translation, let fraction = progress.fraction {
                translationDownload = .init(fraction: fraction, receivedBytes: 0, totalBytes: 0)
            }
        case let .failure(failure):

            switch failure {
            case let .recognition(message):
                sessionWarning = message
            case let .translation(message):
                sessionWarning = message
                if captionsRunning { captionsOverlay.showTranslation("") }
                FileHandle.standardError.write(Data("Translation failed: \(message)\n".utf8))
            case let .capture(message):
                sessionWarning = message
                captureFailed = true
                endRecording()
            case let .recording(message):

                FileHandle.standardError.write(Data("Diagnostic audio failed: \(message)\n".utf8))
            }
        default: break
        }
    }

    @ObservationIgnored private var promptedAccessibility = false
    @ObservationIgnored private var isPreparing = false
    @ObservationIgnored private var preparationTask: Task<Void, Never>?

    /// Which pipeline owns the live session, and whether its stop comes from a
    /// second tap rather than the key release. Both latched at start so a mode
    /// change mid-session cannot strand a running mic.
    @ObservationIgnored private var captionsRunning = false
    /// Readable so tests can prove a menu start latches tap-off.
    @ObservationIgnored private(set) var latchedToggle = false

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

    var supportedLanguageCodes: [String] { [SpeechLanguage.automatic] + LanguagePair.qualityLanguages.sorted() }

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
        if let sessionWarning { return sessionWarning }
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
        if let sessionWarning { return sessionWarning }
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
        case .loadingModels: return .transcribing
        case .transcribed: return .success
        case .idle: return .idle
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
            connectSession()
        case .hotkeys:
            KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.hotkeyDown(submit: false) }
            KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.hotkeyUp() }
            KeyboardShortcuts.onKeyDown(for: .dictateAndSend) { [weak self] in self?.hotkeyDown(submit: true) }
            KeyboardShortcuts.onKeyUp(for: .dictateAndSend) { [weak self] in self?.hotkeyUp() }
        case .microphonePermission:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
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
        prepare(mode: ModelSetting.current)
    }

    /// Prepares the selected pair through the common owner before the next recording.
    func prepareTranslation() {
        let previousPreparation = translationPrepare
        previousPreparation?.cancel()
        translationDownload = nil
        translationGeneration &+= 1
        let generation = translationGeneration
        if captionsRunning, state == .recording {
            updateCaptionTarget()
            return
        }
        guard !isActive else { return }
        let source = SpeechLanguage.current
        guard let target = TranslationSetting.target,
              TranslationSetting.canTranslate(from: source) else { return }
        let pendingSpeech = preparationTask
        translationPrepare = Task { [weak self] in
            await previousPreparation?.value
            await pendingSpeech?.value
            guard let self, !Task.isCancelled else { return }
            do {
                let profile = try SpeechRecognitionProfile.resolve(language: source, mode: ModelSetting.current)
                try await session.prepare(.init(profile: profile, target: target))
            } catch is CancellationError {
            } catch {
                FileHandle.standardError.write(Data("Translation preparation failed: \(error.localizedDescription)\n".utf8))
            }
            if translationGeneration == generation { translationDownload = nil }
        }
    }

    /// The picker owns the desired target; the shared session owns cancellation,
    /// cache invalidation and stale-result protection.
    func updateCaptionTarget() {
        captionsOverlay.setTranslationTarget(captionSource.map(TranslationSetting.badge(dictating:)) ?? "")
        let target = captionSource.flatMap { TranslationSetting.canTranslate(from: $0) ? TranslationSetting.target : nil }
        captionTarget = target
        captionsOverlay.showTranslation("")
        let previous = captionTranslateTask
        previous?.cancel()
        captionTranslateTask = Task { [session] in
            await previous?.value
            do {
                try Task.checkCancellation()
                try await session.setTranslation(target: target, priority: .quality)
            }
            catch is CancellationError {} catch {
                FileHandle.standardError.write(Data("Translation failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    /// Presentation progress; the common session owns downloads and warm-up.
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
        isPreparing = true
        state = .loadingModels
        let pendingTranslation = translationPrepare
        pendingTranslation?.cancel()
        preparationTask = Task { @MainActor in
            await pendingTranslation?.value
            defer { isPreparing = false }
            do {
                let profile = try SpeechRecognitionProfile.resolve(language: SpeechLanguage.current, mode: mode)
                try await session.prepare(.init(profile: profile))
                if case .loadingModels = state { state = .idle }
            } catch { state = .error("model load: \(error.localizedDescription)") }
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

    /// The popover's Start/Stop, for anyone without the shortcut to hand.
    /// Always tap-on / tap-off: a click leaves no key to release.
    func toggleFromMenu() {
        if state == .recording { endRecording() } else { beginRecording(submit: false, forceToggle: true) }
    }

    /// Not `private`: tests drive this with a substituted session to prove
    /// what it latches.
    func beginRecording(submit: Bool, forceToggle: Bool = false) {
        guard !isActive, !isPreparing else { return }
        let language = SpeechLanguage.current
        let modelMode = ModelSetting.current.effective(for: language)
        guard session.isPrepared || translationPrepare != nil else { prepare(mode: modelMode); return }
        let captions = AppMode.current == .captions
        let toggle = forceToggle || Self.togglesOnPress
        submitOnFinish = captions ? false : submit
        sessionWarning = nil
        captureFailed = false
        starting = true
        stopAfterStart = false
        latchedToggle = toggle
        state = .recording
        connectSession()
        let pendingTranslation = translationPrepare
        recordingTask = Task {
            defer { starting = false }
            do {
                await pendingTranslation?.value
                let profile = try SpeechRecognitionProfile.resolve(language: language, mode: modelMode)
                // Translate captions continuously; dictation chooses its output target at Stop.
                let target = captions && TranslationSetting.canTranslate(from: language) ? TranslationSetting.target : nil
                do {
                    try await session.prepare(.init(profile: profile, target: target))
                } catch {
                    guard target != nil else { throw error }
                    // A translation model failure must not prevent live original captions.
                    try await session.prepare(.init(profile: profile))
                }
                try await session.start(microphoneUID: MicrophoneSetting.currentUID,
                                        recordingURL: captions ? nil : diagnosticRecordingURL())
                captionsRunning = captions
                dictationSource = language
                dictationMode = modelMode
                captionSource = captions ? language : nil
                captionTarget = target
                PostHogSDK.shared.capture(captions ? "captions_started" : "dictation_started", properties: [
                    "model_mode": modelMode.rawValue, "language": language,
                    "trigger_mode": TriggerMode.current.rawValue,
                    "insert_mode": Self.insertModeAnalyticsValue,
                ])
                if captions {
                    captionsOverlay.begin(target: TranslationSetting.badge(dictating: language),
                                          display: CaptionsDisplay.current)
                } else {
                    hud.begin(lang: SpeechLanguage.badge(for: language),
                              target: TranslationSetting.badge(dictating: language),
                              interactive: toggle, submits: submitOnFinish,
                              shortcutLabel: activeShortcutLabel(submit: submitOnFinish),
                              onStop: { [weak self] in self?.endRecording() })
                }
                starting = false
                if stopAfterStart { endRecording() }
            } catch {
                state = .error(error.localizedDescription)
                hud.error(error.localizedDescription)
                PostHogSDK.shared.capture("dictation_failed", properties: ["error": error.localizedDescription])
            }
        }
    }

    private func diagnosticRecordingURL() -> URL? {
        guard UserDefaults.standard.bool(forKey: DictationSession.recordUtterancesKey) else { return nil }
        let directory = DiagnosticRecordings.directory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("\(DiagnosticRecordings.filePrefix)\(UUID().uuidString).wav")
        } catch {
            FileHandle.standardError.write(Data("Diagnostic audio failed: \(error.localizedDescription)\n".utf8))
            return nil
        }
    }

    /// Events arrive on the main actor so final HUD presentation cannot be
    /// overtaken by a queued update from the previous utterance.
    private func echo(_ confirmed: String, _ partial: String) {
        if captionsRunning {
            captionsOverlay.update(confirmed: confirmed, partial: partial)
        } else {
            hud.update(confirmed: confirmed, partial: partial)
        }
        #if DEBUG
        let line = partial.isEmpty ? confirmed : "\(confirmed) ⟨\(partial)⟩"
        let tail = line.count > 100 ? "…" + String(line.suffix(100)) : line
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(tail)".utf8))
        #endif
    }

    func endRecording() {
        guard state == .recording else { return }
        if starting { stopAfterStart = true; return }
        state = .transcribing
        let captions = captionsRunning
        let displayOnly = captions || captureFailed
        let modelModeAtStop = completedModelMode.rawValue
        let submitAtStop = submitOnFinish
        let target = TranslationSetting.canTranslate(from: translationSource) ? TranslationSetting.target : nil
        captionTranslateTask?.cancel()
        if captions { captionsOverlay.dismiss() } else { hud.finalizing() }
        recordingTask = Task {
            defer {
                if !captions { Task.detached(priority: .utility) { DiagnosticRecordings.sweep() } }
            }
            do {
                // Close the microphone before potentially preparing a newly selected translation.
                let source = try await session.stopSource()
                var result = source
                if !displayOnly && !captureFailed {
                    do {
                        try await session.setTranslation(target: target, priority: .quality)
                        if target != nil { hud.translating() }
                    } catch {
                        sessionWarning = "Translation failed: \(error.localizedDescription)"
                    }
                } else if captureFailed {
                    try await session.setTranslation(target: nil, priority: .quality)
                }
                do {
                    result = try await session.finishTranslation()
                } catch {
                    // Always finish the shared lifecycle, even if target preparation failed.
                    // The original remains the atomic delivery fallback.
                    sessionWarning = "Translation failed: \(error.localizedDescription)"
                }
                let final = result.text
                if displayOnly || captureFailed {
                    if !captions {
                        hud.finish(final, delivery: .displayedOnly)
                    } else if captureFailed {
                        // The band just vanished mid-talk; say why on the speaker's screen.
                        hud.error(sessionWarning ?? "")
                    }
                    PostHogSDK.shared.capture("captions_completed", properties: [
                        "phrase_count": result.transcript.utterances.count, "character_count": final.count,
                    ])
                } else {
                    let translated = Self.completeTranslation(in: result.transcript)
                    let payload = translated.isEmpty ? final : translated
                    let delivery = payload.isEmpty ? TranscriptDelivery.typed : insertFinal(payload, submit: submitAtStop)
                    hud.finish(final, delivery: delivery, translation: translated, translationIsQuality: !translated.isEmpty && session.configuration?.translationQuality == .quality)
                    PostHogSDK.shared.capture("dictation_completed", properties: [
                        "word_count": final.split(separator: " ").count, "character_count": final.count,
                        "is_empty": final.isEmpty, "model_mode": modelModeAtStop,
                        "insert_mode": Self.insertModeAnalyticsValue, "submit_on_finish": submitAtStop,
                        "delivered": delivery == .typed,
                    ])
                }
                captionsRunning = false
                captionSource = nil
                captionTarget = nil
                state = .transcribed(final)
            } catch {
                state = .error(error.localizedDescription)
                hud.error(error.localizedDescription)
            }
        }
    }

    /// A failed phrase must never turn one atomic paste into a truncated message.
    static func completeTranslation(in transcript: RecordingTranscript) -> String {
        guard !transcript.utterances.isEmpty,
              transcript.utterances.allSatisfy({
                  $0.translationFailed != true && !($0.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return "" }
        return transcript.translatedText
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
