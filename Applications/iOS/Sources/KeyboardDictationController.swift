import SwiftUI
import AVFoundation
import ActivityKit
import MurmurCore
import MurmurSpeech
import MurmurTranslation

@MainActor @Observable final class KeyboardDictationController {
    var configuration: KeyboardConfiguration
    private(set) var state: KeyboardSessionState
    private(set) var isActive = false
    private var preparationCount = 0
    @ObservationIgnored private var enableTask: Task<Void, Never>?
    var hasPendingPreparation: Bool { preparationCount > 0 }
    private(set) var detail = ""
    @ObservationIgnored private var speech: BackgroundSpeechSession?
    @ObservationIgnored private var directSpeech: DirectSpeechSession?
    @ObservationIgnored private var usesDirectTranslation = false
    @ObservationIgnored private var translator: TranslationSession?
    @ObservationIgnored private let repository = NoteRepository(directory: StoragePaths.notes)
    private var conversation = RecordingTranscript()
    private var utteranceAudio: RecordedAudio?
    private var utteranceStartedAt: Date?
    private var lastAudioDraftSave = Date.distantPast
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var lastWidgetStatus: String?
    @ObservationIgnored private var ending = false
    @ObservationIgnored private var lastCommandID: UUID?
    @ObservationIgnored private var lastUse = Date()
    @ObservationIgnored private var lastHeartbeat = Date()
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var translationJob = UUID()
    @ObservationIgnored private var pendingTranslation = ""
    @ObservationIgnored private var lastTranslated = ""
    @ObservationIgnored private var activity: Activity<RecordingAttributes>?
    #if DEBUG
    @ObservationIgnored private var diagnostic: [String: Any] = [:]
    #endif
    init() {
        let source = UserDefaults.standard.string(forKey: "speechLanguage") ?? "ru"
        let saved = UserDefaults.standard.data(forKey: "keyboardConfiguration").flatMap { try? JSONDecoder().decode(KeyboardConfiguration.self, from: $0) }
        let initial = saved ?? KeyboardConfiguration(source: SpeechModelChoice.parakeetLanguages.contains(source) ? source : "en")
        configuration = initial
        state = .init(configuration: initial)
    }
    var summaryTitle: String {
        switch state.phase { case .preparing: return "Preparing…"; case .recording: return "Listening"; case .finalizing: return "Refining"; case .ready, .result: return "Ready to dictate"; case .inactive, .failed: return "Activation needed" }
    }
    var microphoneAllowed: Bool { AVAudioApplication.shared.recordPermission == .granted }
    var fullAccessConfirmed: Bool {
        guard let heartbeat = KeyboardSessionStore.heartbeat, heartbeat.sessionID == state.sessionID else { return false }
        return abs(heartbeat.date.timeIntervalSinceNow) < 10
    }
    var modelsReady: Bool { isActive && [.ready, .recording, .finalizing, .result].contains(state.phase) }
    var languages: [(code: String, name: String)] { AppLanguages.all.filter { SpeechModelChoice.parakeetLanguages.contains($0.code) } }
    var translationLanguages: [(code: String, name: String)] { LanguagePair.qualityLanguages.sorted().map { ($0, AppLanguages.name($0)) } }
    func activateFromKeyboard() async {
        if let requested = KeyboardSessionStore.configuration, requested.isValid {
            if isActive && requested != configuration { await end() }
            if !isActive { configuration = requested }
        }
        await enable()
    }
    func enable() async {
        guard !isActive, enableTask == nil, configuration.isValid, UIApplication.shared.applicationState == .active else { return }
        preparationCount += 1
        let task = Task { await performEnable() }
        enableTask = task
        defer { enableTask = nil; preparationCount -= 1 }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func performEnable() async {
        guard !Task.isCancelled else { return }
        operation = UUID(); let token = operation
        usesDirectTranslation = DirectSpeechTranslation.shouldUse(
            enabled: UserDefaults.standard.bool(forKey: "directSpeechTranslationEnabled"),
            source: configuration.source, target: configuration.target,
            deviceEligible: Self.directTranslationDeviceEligible)
        isActive = true
        state = .init(phase: .preparing, configuration: configuration,
                      translationMethod: configuration.target == nil ? nil : usesDirectTranslation ? .direct : .throughText)
        lastUse = Date(); lastHeartbeat = Date(); lastCommandID = nil
        detail = L10n.text("Preparing dictation…")
        do { try KeyboardSessionStore.saveConfiguration(configuration) }
        catch { await end(message: L10n.text("Could not update the keyboard. Open Murmator and try again.")); return }
        publish(); observeInterruptions(); startTimer()
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw KeyboardError.microphone }
            guard token == operation else { throw CancellationError() }
            guard UIApplication.shared.applicationState == .active else { throw KeyboardError.needsForeground }
            if usesDirectTranslation {
                detail = L10n.text("Preparing direct translation…"); publish()
                let input = DirectSpeechSession(computeMode: .backgroundCPU)
                directSpeech = input
                input.onCapture = { [weak self] _, peak in Task { @MainActor in
                    guard let self, self.operation == token else { return }; self.state.level = min(1, peak * 6)
                } }
                input.onError = { [weak self] _ in Task { @MainActor in
                    guard let self, self.operation == token, self.isActive else { return }
                    await self.end(message: L10n.text("Recording stopped. The captured text was kept."))
                } }
                try input.arm()
                state.microphoneActive = true; publish()
                do { try await input.prepare() }
                catch is CancellationError {
                    await input.close(); directSpeech = nil
                    throw CancellationError()
                } catch {
                    await input.close(); directSpeech = nil; usesDirectTranslation = false
                    try Task.checkCancellation()
                    guard token == operation, isActive else { throw CancellationError() }
                    state.translationMethod = .throughText
                    state.error = L10n.text("Direct translation is unavailable. Translation through text will be used.")
                    detail = state.error ?? ""
                    publish()
                    try await prepareConventionalInput(token: token)
                }
            } else {
                try await prepareConventionalInput(token: token)
            }
            guard token == operation else { throw CancellationError() }
            state.phase = .ready; state.microphoneActive = true
            detail = L10n.text("Return to your app and hold the microphone on the Murmator keyboard.")
            lastUse = Date(); lastHeartbeat = Date()
            if let data = try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data, forKey: "keyboardConfiguration") }
            if ActivityAuthorizationInfo().areActivitiesEnabled {
                activity = try? Activity.request(attributes: RecordingAttributes(startedAt: Date(), keyboard: true),
                    content: ActivityContent(state: .init(phase: L10n.text("Keyboard microphone enabled")), staleDate: nil))
            }
            publish()
        } catch {
            guard token == operation else { return }
            let message: String
            if case KeyboardError.microphone = error { message = L10n.text("Allow microphone access in Settings to record a note.") }
            else if case KeyboardError.needsForeground = error { message = L10n.text("Open Murmator to finish preparation.") }
            else { message = L10n.text("Could not load dictation models.") }
            await end(message: message)
        }
    }
    private static var directTranslationDeviceEligible: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        ProcessInfo.processInfo.physicalMemory >= 5 * 1_024 * 1_024 * 1_024
        #else
        true
        #endif
    }
    private func prepareConventionalInput(token: UUID) async throws {
        let choice: SpeechModelChoice = configuration.source == "ru" && configuration.mode == .fast ? .gigaam : .parakeet
        let input = BackgroundSpeechSession(choice: choice, mode: configuration.mode, language: configuration.source, modelsRoot: StoragePaths.models)
        speech = input
        input.onSnapshot = { [weak self] id, snapshot in Task { @MainActor in
            guard let self, self.operation == token, self.state.utteranceID == id, self.state.phase == .recording else { return }
            guard self.conversation.apply(snapshot) else { return }
            self.state.text = self.conversation.text; self.queueTranslation(self.state.text, token: token, utterance: id); self.publish()
            if Date().timeIntervalSince(self.lastAudioDraftSave) >= 1 {
                self.lastAudioDraftSave = Date()
                if let note = self.recordedNote(complete: false) {
                    do { try await self.repository.saveProgress(note) } catch { self.state.error = L10n.text("Could not save the note") }
                }
            }
        } }
        input.onRecordingError = { [weak self] message in Task { @MainActor in
            guard let self, self.operation == token else { return }
            await self.end(message: L10n.text("Could not save audio.") + " " + message)
        } }
        input.onLevel = { [weak self] peak in Task { @MainActor in
            guard let self, self.operation == token else { return }; self.state.level = min(1, peak * 6)
        } }
        input.onError = { [weak self] _ in Task { @MainActor in
            guard let self, self.operation == token, self.isActive else { return }
            await self.end(message: L10n.text("Recording stopped. The captured text was kept."))
        } }
        try input.arm()
        state.microphoneActive = true; publish()
        try await input.prepare()
        try Task.checkCancellation()
        guard token == operation else { throw CancellationError() }
        if let target = configuration.target {
            detail = L10n.text("Preparing translation…")
            let session = TranslationSession(modelsRoot: StoragePaths.translation)
            translator = session
            try await session.prepare(from: configuration.source, to: target) { [weak self] progress in
                self?.detail = "\(L10n.text("Preparing translation…")) · \(Int(progress.fraction * 100))%"
                self?.publish()
            }
            detail = L10n.text("Preparing…"); publish()
            try await session.warmUp(from: configuration.source, to: target)
        }
    }
    func startUtterance(id: UUID = UUID()) async {
        guard isActive, state.phase == .ready || state.phase == .result else { return }
        guard usesDirectTranslation ? directSpeech != nil : speech != nil else { return }
        let token = operation
        state.utteranceID = id; state.text = ""; state.translation = ""; state.error = nil
        translationJob = UUID(); translationTask?.cancel(); translationTask = nil; pendingTranslation = ""; lastTranslated = ""
        state.phase = .recording; state.recordingStartedAt = Date(); lastUse = Date()
        utteranceStartedAt = state.recordingStartedAt; utteranceAudio = RecordedAudio(recordingID: id)
        conversation = RecordingTranscript(); lastAudioDraftSave = .distantPast
        publish()
        do {
            if let note = recordedNote(complete: false) { try await repository.save(note) }
            if usesDirectTranslation, let directSpeech, let target = configuration.target {
                try directSpeech.begin(source: configuration.source, target: target,
                    recordingURL: utteranceAudio?.url(in: StoragePaths.recordings),
                    onBatch: { [weak self] value in
                        guard let self, self.operation == token, self.state.utteranceID == id,
                              self.state.phase == .recording || self.state.phase == .finalizing else { throw CancellationError() }
                        self.conversation.appendSettled(value)
                        self.state.text = self.conversation.text; self.state.translation = self.conversation.translatedText
                        self.publish()
                        if let note = self.recordedNote(complete: false) { try await self.repository.saveProgress(note) }
                    })
            } else if let speech {
                try await speech.begin(id, recordingURL: utteranceAudio?.url(in: StoragePaths.recordings))
            } else { throw CancellationError() }
        }
        catch { if token == operation { await end(message: L10n.text("Could not start dictation. Check microphone access and language downloads.")) } }
        await activity?.update(.init(state: .init(phase: L10n.text("Listening")), staleDate: nil))
    }
    func stopUtterance() async {
        guard state.phase == .recording else { return }
        let token = operation, id = state.utteranceID
        state.phase = .finalizing; lastUse = Date(); publish()
        translationTask?.cancel(); translationTask = nil
        do {
            if usesDirectTranslation, let directSpeech {
                let result = try await directSpeech.finish()
                guard operation == token, state.utteranceID == id else { return }
                state.text = conversation.text; state.translation = conversation.translatedText
                if state.text.isEmpty { state.error = L10n.text("No speech detected. Hold the microphone and try again.") }
                if let note = recordedNote(complete: true, duration: result.duration) { try await repository.save(note) }
                state.phase = .result; state.recordingStartedAt = nil; lastUse = Date(); publish()
                await activity?.update(.init(state: .init(phase: L10n.text("Keyboard microphone enabled")), staleDate: nil))
                return
            }
            guard let speech else { throw CancellationError() }
            let result = try await speech.finish()
            #if DEBUG
            diagnostic = ["audioSeconds": result.seconds, "speechWindows": result.speechWindows,
                "maximumSpeechProbability": result.maximumSpeechProbability, "maximumInputLevel": result.maximumInputLevel,
                "recognitionPasses": result.recognitionPasses,
                "inputRoute": AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.portType.rawValue },
                "outputRoute": AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }]
            #endif
            guard operation == token, state.utteranceID == id else { return }
            conversation.apply(result.snapshot)
            conversation.finish(fallback: result.text, endSample: Int(result.seconds * 16_000))
            state.text = conversation.text
            if let note = recordedNote(complete: true, duration: result.seconds) { try await repository.save(note) }
            if state.text.isEmpty { state.error = L10n.text("No speech detected. Hold the microphone and try again.") }
            if let target = state.configuration.target, !state.text.isEmpty, let translator {
                do {
                    try await translator.finishUtterances(conversation.utterances, from: state.configuration.source, to: target) { [weak self] value in
                        await self?.translated(value, token: token)
                    }
                } catch { state.error = L10n.text("Translation could not be completed. Your original text is kept.") }
                state.translation = conversation.translatedText
            }
            guard operation == token, state.utteranceID == id else { return }
            if let note = recordedNote(complete: true, duration: result.seconds) {
                do { try await repository.save(note) }
                catch { state.error = L10n.text("Could not save the note") }
            }
            guard operation == token else { return }
            state.phase = .result; state.recordingStartedAt = nil; lastUse = Date(); publish()
            await activity?.update(.init(state: .init(phase: L10n.text("Keyboard microphone enabled")), staleDate: nil))
        } catch { if token == operation { await end(message: L10n.text("Recording stopped. The captured text was kept.")) } }
    }
    func cancelUtterance() async {
        guard state.phase == .recording else { return }
        let note = recordedNote(complete: false, closed: true)
        state.phase = .ready; state.utteranceID = nil; state.text = ""; state.translation = ""; state.error = nil; state.recordingStartedAt = nil
        translationTask?.cancel(); translationTask = nil; lastUse = Date(); publish()
        if usesDirectTranslation { await directSpeech?.cancelUtterance() } else { await speech?.discard() }
        if let note { try? await repository.save(note) }
    }
    func end(message: String? = nil) async {
        guard isActive, !ending else { return }
        ending = true
        enableTask?.cancel()
        let capturedNote = recordedNote(complete: state.phase == .result, closed: true)
        operation = UUID()
        timer?.invalidate(); timer = nil
        translationTask?.cancel(); translationTask = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
        let input = speech; speech = nil
        let directInput = directSpeech; directSpeech = nil
        state.microphoneActive = false; state.phase = message == nil ? .inactive : .failed
        state.error = message; state.recordingStartedAt = nil; publish()
        await input?.close()
        await directInput?.close()
        if let capturedNote { try? await repository.saveProgress(capturedNote) }
        await translator?.unload(); translator = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        await activity?.end(nil, dismissalPolicy: .immediate); activity = nil
        isActive = false; usesDirectTranslation = false; ending = false; publish()
    }
    private func translated(_ value: UtteranceTranslation, token: UUID) {
        guard token == operation else { return }; conversation.applyTranslations([value])
    }
    private func recordedNote(complete: Bool, duration: Double? = nil, closed: Bool = false) -> VoiceNote? {
        guard let id = state.utteranceID, let audio = utteranceAudio else { return nil }
        var note = VoiceNote(id: id, createdAt: utteranceStartedAt ?? Date(), text: conversation.text,
            translation: conversation.translatedText.isEmpty ? nil : conversation.translatedText,
            sourceLanguage: state.configuration.source, targetLanguage: state.configuration.target,
            duration: audio.capturedDuration(in: StoragePaths.recordings) ?? duration ?? utteranceStartedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0,
            model: usesDirectTranslation ? "direct-speech-translation" : "keyboard · \(state.configuration.mode.rawValue)")
        note.audio = audio; note.utterances = conversation.utterances; note.captureRevision = conversation.revision
        note.transcriptionComplete = complete
        note.captureClosed = complete || closed
        note.translationIncomplete = state.configuration.target != nil && (!complete || conversation.utterances.contains { $0.translation == nil })
        if note.text.isEmpty { note.sourceFileName = L10n.text("Audio recording") }
        return note
    }
    func stopAndEnd() async {
        if state.phase == .recording { await stopUtterance() }
        await end()
    }
    private func queueTranslation(_ text: String, token: UUID, utterance: UUID) {
        guard configuration.target != nil else { return }
        pendingTranslation = text
        guard translationTask == nil else { return }
        let job = UUID(); translationJob = job
        translationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.operation == token && self.translationJob == job { self.translationTask = nil } }
            while !Task.isCancelled, self.operation == token, self.state.phase == .recording, self.state.utteranceID == utterance,
                  self.pendingTranslation != self.lastTranslated, let target = self.configuration.target, let preview = self.translator {
                let source = self.pendingTranslation
                do {
                    let output = try await preview.preview(source, from: self.configuration.source, to: target)
                    guard !Task.isCancelled, self.operation == token, self.state.phase == .recording, self.state.utteranceID == utterance else { return }
                    self.lastTranslated = source; self.state.translation = output; self.publish()
                } catch { self.lastTranslated = source; return }
            }
        }
    }
    private func publish() {
        let widgetStatus = state.phase == .preparing ? "Preparing…" : !state.microphoneActive ? (isActive ? "Freeing memory…" : "Inactive") : "Ready"
        if lastWidgetStatus != widgetStatus {
            lastWidgetStatus = widgetStatus
            var widget = MurMurWidgetState.read()
            widget.status = widgetStatus; widget.updatedAt = Date(); widget.save()
        }
        state.updatedAt = Date()
        state.preparationDetail = state.phase == .preparing ? detail : nil
        #if DEBUG
        if let data = try? JSONEncoder().encode(state), let value = try? JSONSerialization.jsonObject(with: data),
           let diagnostic = try? JSONSerialization.data(withJSONObject: ["state": value, "audio": diagnostic, "applicationState": UIApplication.shared.applicationState == .background ? "background" : "foreground"]) {
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("keyboard-session-debug.json")
            try? diagnostic.write(to: file, options: [.atomic, .completeFileProtection])
        }
        #endif
        do { try KeyboardSessionStore.publish(state) }
        catch {
            if isActive { Task { await self.end(message: L10n.text("Could not update the keyboard. Open Murmator and try again.")) } }
        }
    }
    private func startTimer() {
        let next = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = next; RunLoop.main.add(next, forMode: .common)
    }
    private func tick() {
        guard isActive else { return }
        let now = Date()
        if let heartbeat = KeyboardSessionStore.heartbeat, heartbeat.sessionID == state.sessionID,
           now.timeIntervalSince(heartbeat.date) >= -2, now.timeIntervalSince(heartbeat.date) < 5 { lastHeartbeat = now }
        if let command = KeyboardSessionStore.command, command.isValid(for: state, lastCommandID: lastCommandID) {
            lastCommandID = command.id; lastUse = now
            switch command.action {
            case .start: if let id = command.utteranceID { Task { await startUtterance(id: id) } }
            case .stop: Task { await stopUtterance() }
            case .cancel: Task { await cancelUtterance() }
            case .end: Task { await stopAndEnd() }
            }
        }
        if state.phase == .finalizing && now.timeIntervalSince(lastUse) > 45 {
            Task { await end(message: L10n.text("Recording stopped. The captured text was kept.")) }
        } else if state.phase == .recording, let began = state.recordingStartedAt, now.timeIntervalSince(began) > 180 {
            Task { await stopUtterance() }
        } else if state.phase != .finalizing && state.microphoneActive && (now.timeIntervalSince(lastUse) > 300 || UIApplication.shared.applicationState != .active && now.timeIntervalSince(lastHeartbeat) > 60) {
            Task { if self.state.phase == .recording { await self.stopUtterance() }; await self.end() }
        }
        publish()
    }
    private func observeInterruptions() {
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification, UIApplication.protectedDataWillBecomeUnavailableNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.end(message: L10n.text("Recording stopped. The captured text was kept.")) }
            })
        }
    }
    private enum KeyboardError: Error { case microphone, needsForeground }
}
