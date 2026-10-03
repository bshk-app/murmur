// UI-only host: the production SwiftUI views run unchanged, with no inference libraries.
// Design-capture states are explicit fixtures, never inference/download evidence.
import SwiftUI
import AVFoundation
import MurmurCore

@MainActor @Observable final class AppModel {
    enum Phase { case idle, preparing, ready, recording, refining }
    var phase = Phase.idle
    var directTranslationEnabled = false
    var directTranslationSelected: Bool { directTranslationEnabled && source != target && (source == "en" || target == "en") }
    var directTranslationUnavailableOnDevice = false
    var conversation = RecordingTranscript()
    var liveTranslationSegments: [UtteranceTranslation] = []
    func audioURL(for note: VoiceNote) -> URL? {
        guard let url = try? note.audio?.url(in: StoragePaths.recordings), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    func retranscribe(_ note: VoiceNote) async {
        var job = AudioImportJob(filename: "Повторная расшифровка.wav", storedFilename: "fixture.wav", language: note.sourceLanguage, model: "UI fixture")
        job.id = note.id; job.audio = note.audio; job.previousVersion = TranscriptVersion(note: note)
        audioImports.jobs = [job]; showAudioImport = true
    }
    func removeSpeechLanguage(_ code: String) async { languageLibrary.removeSpeech(code) }
    func removeTranslationLanguage(_ pack: TranslationLanguagePack) async { languageLibrary.removeTranslation(pack) }
    var pendingUtilityRoute: String?
    var showSafariSetup = false
    func requestUtilityRoute(_ route: String) {
        guard !showRecorder else { error = L10n.text("Finish the current task to free memory."); return }
        pendingUtilityRoute = route
        if showSafariSetup {
            if route == "safari-setup" { pendingUtilityRoute = nil; return }
            showSafariSetup = false; return
        }
        if showAudioImport {
            if route == "audio-import" { pendingUtilityRoute = nil; return }
            if audioImports.busy { return }
            showAudioImport = false; return
        }
        if showKeyboardSetup { showKeyboardSetup = false; return }
        if showTranslation { showTranslation = false; return }
        if showLanguages { showLanguages = false; return }
        if showMemory { showMemory = false; return }
        if showStorage { showStorage = false; return }
        consumeUtilityRoute()
    }
    func consumeUtilityRoute() {
        guard let route = pendingUtilityRoute, !textTranslator.isBusy, !managingStorage, !showSafariSetup, !showKeyboardSetup, !showTranslation, !showLanguages, !showMemory, !showStorage, !showAudioImport else { return }
        pendingUtilityRoute = nil
        switch route {
        case "audio-import": showAudioImport = true
        case "keyboard": showKeyboardSetup = true; Task { await enableKeyboard() }
        case "settings": showSettings = true
        case "safari-setup": showSafariSetup = true
        case "languages": showLanguages = true
        case "record": Task { await keyboard.stopAndEnd(); await start() }
        case "translate": Task { await keyboard.stopAndEnd(); showTranslation = true }
        case "storage": showStorage = true
        case "memory": showMemory = true
        case "release-memory": showMemory = true; Task { await releaseModels() }
        default: break
        }
    }
    let textTranslationEngine: UIHostTextTranslationEngine
    let textTranslator: TextTranslationModel
    init(textScenario: UIHostTextTranslationEngine.Scenario = .success, textResult: String? = nil) {
        let engine = UIHostTextTranslationEngine(scenario: textScenario, result: textResult)
        textTranslationEngine = engine
        textTranslator = TextTranslationModel(engine: engine, source: "ru", target: "fi",
            availableTargets: { from in LanguagePair.qualityLanguages.sorted().filter { LanguagePair.qualityRoute(from: from, to: $0) != nil } })
    }
    func startTextTranslation() async { textTranslator.start() }
    let audioImports = AudioImportController()
    var showAudioImport = false
    func receiveAudio(_ url: URL) async {
        if !showRecorder { requestUtilityRoute("audio-import") }
        await audioImports.receive(url, language: source, model: speechModel)
    }
    func startAudioImport(_ id: UUID) async {
        if audioImports.activeID != nil { audioImports.start(id); return }
        guard canReleaseMemory else { return }
        await releaseModels()
        audioImports.start(id)
    }
    func openImport(for note: VoiceNote) { audioImports.selectedID = note.id; requestUtilityRoute("audio-import") }
    func importMayUpdate(_ note: VoiceNote) -> Bool { note.transcriptionComplete == false && audioImports.jobs.contains { $0.id == note.id && $0.status != .completed } }
    var showStorage = false
    var storageInventory = ModelStorageInventory()
    var storageLoading = false
    var storageReadFailed = false
    var managingStorage = false
    var storageError: String?
    var storageMessage: String?
    private var storageSeeded = false
    private let modelStorage = ModelStorage(modelsRoot: StoragePaths.support.appendingPathComponent("UIStorageFixtures"))
    var canManageStorage: Bool { !busy && !preparingAll && !keyboard.hasPendingPreparation }
    func refreshStorage() async {
        if LongConversationHost.scenario == "storage" {
            storageInventory = .init(items: [
                .init(id: "speech/multilingual-accurate", kind: .speech, title: "Multilingual speech recognition", detail: "Shared by several dictation languages and keyboard sessions.", bytes: 335_700_000),
                .init(id: "speech/russian-accurate", kind: .speech, title: "Russian speech recognition", detail: "Used for Russian dictation and audio imports.", bytes: 224_100_000)
            ], totalBytes: 559_800_000, availableDiskBytes: 20_000_000_000)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--design-capture") { return }
        let fixture = ProcessInfo.processInfo.arguments.contains { $0.trimmingCharacters(in: CharacterSet(charactersIn:"-")) == "storageFixture" }
        if fixture && !storageSeeded {
            let root = StoragePaths.support.appendingPathComponent("UIStorageFixtures/TranslationModels")
            for name in ["ct2-rufi", "ct2-enfi"] {
                let dir = root.appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? Data(repeating: 1, count: 131072).write(to: dir.appendingPathComponent("model.bin"))
            }
            storageSeeded = true
        }
        if ProcessInfo.processInfo.arguments.contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn:"-")) == "storagePendingPreparation" }) { keyboard.hasPendingPreparation = true }
        storageLoading = true; defer { storageLoading = false }
        do { storageInventory = try await modelStorage.inventory(); storageReadFailed = false }
        catch { storageError = error.localizedDescription; storageReadFailed = true }
    }
    func deleteStoredModel(_ item: ModelStorageItem) async {
        guard canManageStorage else { return }
        managingStorage = true; defer { managingStorage = false }
        do { try await modelStorage.remove(id: item.id); storageInventory = try await modelStorage.inventory(); storageMessage = L10n.text("Download removed.") }
        catch { storageError = error.localizedDescription }
    }
    var showMemory = false
    var showSettings = false
    var showLanguages = false
    var showTranslation = false
    var releasingMemory = false
    var translationLoaded = false
    var designLoadedModels = false
    var canReleaseMemory: Bool { phase == .idle && !importing && !preparingAll && !releasingMemory && !audioImports.busy && !textTranslator.isBusy && ![.recording, .finalizing, .preparing].contains(keyboard.state.phase) }
    var hasLoadedModels: Bool { textTranslator.modelsLoaded || designLoadedModels || keyboard.isActive || audioImports.activeID != nil }
    func refreshMemoryState() async {}
    func releaseModels() async {}
    func publishWidgetState() {}
    func publishWatchContext() {}
    func receiveWatchRecordings() async {}
    func scheduleTranscriptionTask() {}
    var showRecorder = false
    var showKeyboardSetup = false
    var keyboardActivationRequested = false
    let keyboard = KeyboardDictationController()
    var notes: [VoiceNote] = [] { didSet { noteList = NoteList(preview: notes) } }
    var noteList = NoteList(repository: NoteRepository(directory: StoragePaths.support.appendingPathComponent("UITestNotes")))
    var selectedNote: VoiceNote?
    var transcript = ""
    var captionDisplay = CorrectionDisplay()
    var translation = ""
    var detail = ""
    var error: String?
    var progress: Progress?
    var translationFraction: Double?
    var levels: [CGFloat] = []
    var isTranslation = false
    var preparingLiveTranslation = false
    func enableLiveTranslation(to language: String) async { target = language; isTranslation = true; translation = LongConversationHost.russian }
    func translateNote(_ note: VoiceNote, to target: String, onProgress: @escaping @MainActor (Double?) -> Void) async throws {
        onProgress(1)
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { throw CancellationError() }
        notes[index].translation = LongConversationHost.russian; notes[index].targetLanguage = target; notes[index].translationNeedsUpdate = false
    }
    var modelReady = false
    var warmingModels = false
    var preparationModel = ""
    var importing = false
    var preparingAll = false
    var preparationPaused = false
    var preparationStepIndex = 0
    var preparationStepCount = 1
    var preparationFraction: Double? { warmingModels ? nil : PreparationProgress.fraction(step: preparationStepIndex, steps: preparationStepCount, current: translationFraction ?? progress?.fractionCompleted ?? 0) }
    var preparationStageLabel: String { L10n.format("Step %d of %d", preparationStepIndex + 1, preparationStepCount) + " · " + preparationModel }
    func pauseLanguagePreparation() async {}
    func resumeLanguagePreparation() async {}
    var activePreparationID: String?
    var preparationErrors: [String: String] = [:]
    var source = UserDefaults.standard.string(forKey: "speechLanguage") ?? "ru"
    var translationQuality = ProcessingQuality.quality
    var target = "en"
    var mode = DictationMode.hybrid
    var speechModel = SpeechModelChoice.gigaam
    var microphoneAllowed = AVAudioApplication.shared.recordPermission == .granted
    let languageLibrary = LanguageLibrary()
    var busy: Bool { phase != .idle || importing || keyboard.isActive || releasingMemory || audioImports.busy || textTranslator.isBusy || managingStorage || keyboard.hasPendingPreparation }
    var duration: Double = 0
    var translationOptions: [String] { availableTranslationTargets(from: source) }
    func availableTranslationTargets(from source: String) -> [String] { LanguagePair.qualityLanguages.sorted().filter { LanguagePair.qualityRoute(from: source, to: $0) != nil } }
    private let repository = NoteRepository(directory: StoragePaths.support.appendingPathComponent("UITestNotes"))
    private var listActionsSeeded = false
    private var paginationSeeding = false

    func loadNote(_ id: UUID) async -> VoiceNote? {
        if let note = notes.first(where: { $0.id == id }) { return note }
        do { return try await repository.note(id) }
        catch { self.error = error.localizedDescription; return nil }
    }
    func currentNote(_ fallback: VoiceNote) -> VoiceNote {
        notes.first { $0.id == fallback.id } ?? (selectedNote?.id == fallback.id ? selectedNote : nil) ?? fallback
    }
    func importMayUpdate(_ note: NoteSummary) -> Bool {
        note.transcriptionComplete == false && audioImports.jobs.contains { $0.id == note.id && $0.status != .completed }
    }
    func refresh() async {
        if ProcessInfo.processInfo.arguments.contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) == "notePaginationFixture" }) {
            guard !paginationSeeding else { return }
            paginationSeeding = true
            defer { paginationSeeding = false }
            do {
                if !UserDefaults.standard.bool(forKey: "paginationNotesSeeded") {
                    for index in 1...123 {
                        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
                        let text = String(format: "Page note %03d", index) + "\n" + String(repeating: "Saved transcript. ", count: 30)
                            + (index == 120 ? "\nNeedle from older transcript" : "")
                        var note = VoiceNote(id: id, createdAt: Date(timeIntervalSince1970: Double(1000 - index)), text: text, sourceLanguage: "en", duration: 60, model: "UI fixture")
                        note.transcriptionComplete = true
                        try await repository.save(note)
                    }
                    UserDefaults.standard.set(true, forKey: "paginationNotesSeeded")
                }
                await noteList.reload(preservingCount: true)
            } catch { self.error = error.localizedDescription }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--design-capture") { return }
        if ProcessInfo.processInfo.arguments.contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) == "listActionsFixture" }) {
            if !listActionsSeeded { await seedListActions(); listActionsSeeded = true }
            notes = (try? await repository.all()) ?? []
            return
        }
        if UserDefaults.standard.bool(forKey: "uiFixture") || ProcessInfo.processInfo.arguments.contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) == "uiFixture" }) { seedUITest(); return }
        notes = (try? await repository.all()) ?? []
    }
    func updateSettings() async { UserDefaults.standard.set(source, forKey: "speechLanguage") }
    func recommendModel() { speechModel = source == "ru" ? .gigaam : .parakeet }
    func requestMicrophonePermission() async { microphoneAllowed = await AVAudioApplication.requestRecordPermission() }
    func prepareModels() async { unavailable() }
    func enableKeyboard(fromExtension: Bool = false) async { await keyboard.enable() }
    func consumeKeyboardActivation() async { keyboardActivationRequested = false; await keyboard.enable() }
    func preloadLanguages(_ languages: Set<String>) async {
        let plan = OfflinePreloadPlan(languages: languages)
        preparationErrors = [:]; preparingAll = true; phase = .preparing
        defer { preparingAll = false; phase = .idle }
        for code in plan.speech {
            languageLibrary.addSpeech(code)
            activePreparationID = "speech:" + code
            preparationModel = AppLanguages.name(code)
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            languageLibrary.markPrepared("speech:" + code)
        }
        for pair in plan.translations {
            languageLibrary.addTranslation(from: pair.source, to: pair.target)
            activePreparationID = "translation:" + pair.source + "-" + pair.target
            preparationModel = AppLanguages.name(pair.source) + " → " + AppLanguages.name(pair.target)
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            languageLibrary.markPrepared(activePreparationID!)
        }
        activePreparationID = nil
    }
    func translationTargets(from source: String) -> [String] {
        availableTranslationTargets(from: source).filter { ProcessingQuality.translationOptions(from: source, to: $0).contains(translationQuality) }
    }
    func validateTranslationQuality() {
        if !ProcessingQuality.translationOptions(from: source, to: target).contains(translationQuality) { translationQuality = .quality }
    }
    func confirmRecording() async {
        guard phase == .ready else { return }
        phase = .recording
        if LongConversationHost.scenario == "onboarding" {
            let words = (source == "ru" ? "Это пример живой транскрипции." : "This is a live transcription example.").split(separator: " ")
            Task { @MainActor [weak self] in
                for index in words.indices {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, self.phase == .recording else { return }
                    self.transcript = words.prefix(index + 1).joined(separator: " ")
                    self.captionDisplay.finish(self.transcript)
                    if self.isTranslation { self.translation = "This is a live translation example." }
                }
            }
        }
    }
    func prepareAllLanguages() async { unavailable() }

    func prepareSpeechLanguage(_ code: String) async { unavailable() }
    func prepareTranslationLanguage(_ pack: TranslationLanguagePack) async { unavailable() }
    func start(translating: Bool = false) async {
        if LongConversationHost.scenario == "onboarding" {
            phase = .preparing; showRecorder = true; isTranslation = translating
            transcript = ""; translation = ""; captionDisplay = CorrectionDisplay(); duration = 0
            try? await Task.sleep(for: .milliseconds(350))
            guard phase == .preparing else { return }
            phase = .ready; detail = L10n.text("Ready. Tap Start recording when you want to speak.")
            return
        }
        guard ProcessInfo.processInfo.arguments.contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) == "correctionFixture" }) else { unavailable(); return }
        phase = .recording; showRecorder = true
        captionDisplay = CorrectionDisplay()
        captionDisplay.update(.init(revision: 1, confirmed: [], provisional: "send the revenu slide"))
        transcript = captionDisplay.text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            guard let self, self.phase == .recording else { return }
            self.captionDisplay.finish("Send the revenue slide")
            self.transcript = self.captionDisplay.text
        }
    }
    func stop() async {
        guard LongConversationHost.scenario == "onboarding", phase == .recording else { return }
        let note = VoiceNote(text: transcript, translation: isTranslation ? translation : nil, sourceLanguage: source, targetLanguage: isTranslation ? target : nil, duration: 3, model: "UI fixture")
        try? await repository.save(note)
        notes = [note]; selectedNote = note; phase = .idle; showRecorder = false
    }
    func cancel() async { phase = .idle; showRecorder = false }
    func interrupted() async {}
    func importModels(_ url: URL) async { unavailable() }
    func delete(_ note: VoiceNote) async {
        guard !importMayUpdate(note) else { return }
        do { try await repository.delete(note.id); await refresh(); selectedNote = nil }
        catch { self.error = error.localizedDescription }
    }
    func saveEdit(_ note: VoiceNote) async {
        do { try await repository.save(note); await refresh(); selectedNote = note }
        catch { self.error = error.localizedDescription }
    }
    private func unavailable() { error = L10n.text("Speech engines are tested on a physical iPhone. This simulator only tests the interface.") }
    func seedUITest() { notes = [VoiceNote(text: "A small idea for tomorrow", sourceLanguage: "en", duration: 18, model: "UI fixture")] }
    private func seedListActions() async {
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let partial = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        if !UserDefaults.standard.bool(forKey: "listActionsNotesSeeded") {
            try? await repository.save(VoiceNote(id: first, createdAt: Date(timeIntervalSince1970: 300), text: "First swipe note", sourceLanguage: "en", duration: 18, model: "UI fixture"))
            try? await repository.save(VoiceNote(id: second, createdAt: Date(timeIntervalSince1970: 200), text: "Keep this note", sourceLanguage: "en", duration: 10, model: "UI fixture"))
            var note = VoiceNote(id: partial, createdAt: Date(timeIntervalSince1970: 100), text: "Saved partial transcript", sourceLanguage: "en", duration: 12, model: "UI fixture")
            note.transcriptionComplete = false
            try? await repository.save(note)
            languageLibrary.addSpeech("en")
            languageLibrary.addTranslation(from: "ru", to: "fi")
            UserDefaults.standard.set(true, forKey: "listActionsNotesSeeded")
        }
        var job = AudioImportJob(id: partial, filename: "Partial recording.m4a", storedFilename: "fixture.m4a", language: "en", model: "UI fixture")
        job.duration = 60; job.status = .paused
        job.segments = [AudioFileSegment(startSample: 0, endSample: 192_000, text: "Saved partial transcript")]
        var queued = AudioImportJob(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, filename: "Queued recording.m4a", storedFilename: "fixture.m4a", language: "en", model: "UI fixture")
        queued.duration = 30; queued.status = .queued; queued.queuedAt = .now
        audioImports.jobs = [job, queued]
        if ProcessInfo.processInfo.arguments.contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) == "activeImportFixture" }) {
            audioImports.activeID = partial; audioImports.jobs[0].status = .processing
        }
    }
}
