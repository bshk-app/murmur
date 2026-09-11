import SwiftUI
import MurmurCore

/// Presentation-only stress fixtures. They exercise production views, not ASR quality.
struct LongConversationHost: View {
    static var scenario: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(where: { $0 == "--long-conversation" || $0 == "-longConversation" }), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    static let first = "Начало собрания. Сегодня обсудим учебный день, домашние задания и поддержку детей."
    static let last = "Конец собрания. Спасибо за участие, следующая встреча состоится в октябре."
    static var russian: String {
        ([first] + (1...240).map { "\($0). Учитель рассказывает о занятиях. Если ребёнку нужна помощь с финским языком, свяжитесь с классным руководителем. Мы вместе составим план поддержки." } + [last]).joined(separator: "\n\n")
    }
    static var finnish: String {
        (["Hyvää iltaa ja tervetuloa vanhempainiltaan."] + (1...240).map { "\($0). Puhumme koulupäivästä ja kotitehtävistä. Jos lapsi tarvitsee tukea suomen kielessä, ottakaa yhteyttä luokanopettajaan." } + ["Kiitos osallistumisesta. Seuraava tapaaminen on lokakuussa."]).joined(separator: "\n\n")
    }
    @State private var onboardingFinished = false
    @State private var model: AppModel
    @State private var textController: TextTranslationModel
    private let note: VoiceNote
    init() {
        let app = AppModel()
        app.source = "fi"; app.target = "ru"; app.duration = 3600
        app.recommendModel(); app.mode = .accurate
        app.phase = .recording; app.isTranslation = true
        app.transcript = Self.finnish; app.translation = Self.russian
        app.captionDisplay.finish(Self.finnish)
        if Self.scenario == "live-original" { app.isTranslation = false }
        app.detail = "Listening"
        var note = VoiceNote(text: Self.finnish, translation: Self.scenario == "note-untranslated" ? nil : Self.russian, sourceLanguage: "fi", targetLanguage: "ru", duration: 3600, model: "UI fixture")
        if ["live", "live-original", "note", "note-untranslated", "audio-note"].contains(Self.scenario ?? "") {
            let original = Self.finnish.components(separatedBy: "\n\n"), translated = Self.russian.components(separatedBy: "\n\n")
            let phrases = original.enumerated().map { index, text in
                CaptionSegment(id: UInt64(index + 1), startSample: index * 57_600_000 / original.count,
                               endSample: (index + 1) * 57_600_000 / original.count, text: text, state: .confirmed)
            }
            app.conversation.apply(.init(revision: 1, confirmed: phrases, provisional: "", settledThroughSample: 57_600_000))
            app.conversation.applyTranslations(phrases.enumerated().map { index, phrase in .init(id: phrase.id, source: phrase.text, text: translated[index], isFinal: true) })
            note.utterances = app.conversation.utterances
        }
        if Self.scenario == "audio-note" {
            let audio = RecordedAudio()
            if let url = try? audio.url(in: StoragePaths.recordings), let writer = try? PCMRecordingWriter(url: url) {
                try? writer.append([Float](repeating: 0, count: 160_000)); try? writer.finish(); note.audio = audio
            }
            var previous = note; previous.text = "Ensimmäinen alkuperäinen litterointi on tallessa."; previous.translation = "Предыдущая расшифровка сохранена."
            note.transcriptVersions = [TranscriptVersion(note: previous)]
        }
        self.note = note; app.notes = [note]
        if !["live", "live-original"].contains(Self.scenario ?? "") { app.phase = .idle }
        app.languageLibrary.speech = ["ru", "en", "fi"]
        app.languageLibrary.translations = [.init(source: "fi", target: "ru")]
        if Self.scenario == "languages-ready" {
            for id in ["speech:ru", "speech:en", "speech:fi", "translation:fi-ru"] { app.languageLibrary.markPrepared(id) }
        }
        if Self.scenario == "recording-ready" {
            app.phase = .ready; app.transcript = ""; app.translation = ""; app.duration = 0
            app.detail = L10n.text("Ready. Tap Start recording when you want to speak.")
        }
        if Self.scenario == "onboarding" { app.source = "ru" }
        if Self.scenario == "priority" { UserDefaults.standard.set("voice", forKey: "translationInputMode") }
        if Self.scenario == "progress" {
            app.phase = .preparing; app.activePreparationID = "translation:fi-ru"
            app.preparationModel = L10n.text("Preparing translation…")
            app.preparationStepCount = 3; app.preparationStepIndex = 1; app.translationFraction = 0.5
        }
        if Self.scenario == "import" {
            var job = AudioImportJob(filename: "Часовая запись.wav", storedFilename: "ui-fixture.wav", language: "fi", model: "UI fixture")
            job.status = .completed; job.duration = 3600
            job.segments = [.init(startSample: 0, endSample: 57_600_000, text: Self.finnish)]
            app.audioImports.jobs = [job]
        }
        _model = State(initialValue: app)
        _textController = State(initialValue: TextTranslationModel(engine: LongConversationFixtureEngine(), source: "fi", target: "ru", availableTargets: { _ in ["ru", "en"] }))
    }
    var body: some View {
        Group {
            switch Self.scenario {
            case "note", "note-untranslated", "audio-note": NavigationStack { NoteDetailView(note: note, model: model) }
            case "text": TextTranslationView(controller: textController, canStart: true) { textController.start() }
            case "compact": CompactTranslationSheet(controller: textController, translate: { textController.start() }, close: {}, expand: {})
            case "languages", "languages-ready", "progress": NavigationStack { LanguageSetupView(model: model) }
            case "priority": TranslationSetupView(model: model, start: {})
            case "storage": StorageView(model: model)
            case "settings": NavigationStack { SettingsView(model: model) }
            case "memory": MemoryView(model: model)
            case "keyboard-setup": KeyboardDictationView(controller: model.keyboard, onEnable: {})
            case "onboarding":
                if onboardingFinished { NotesView(model: model) }
                else {
                    NavigationStack { OnboardingView(model: model) {
                        UserDefaults.standard.set(4, forKey: "onboardingVersion")
                        UserDefaults.standard.set(true, forKey: "onboardingComplete")
                        onboardingFinished = true
                    } }
                }
            case "keyboard": KeyboardResultTestHost()
            case "import": AudioImportView(model: model)
            default: RecordingView(model: model)
            }
        }.task {
            if ["text", "compact"].contains(Self.scenario ?? "") {
                textController.input = String(Self.finnish.prefix(9000))
                await textController.start()?.value
            }
            if ["live", "live-original"].contains(Self.scenario ?? "") {
                for number in 1...180 {
                    let source = "Uusi lause \(number). Keskustelu jatkuu."
                    model.conversation.apply(.init(revision: UInt64(number * 3 + 1), confirmed: [], provisional: source))
                    model.liveTranslationSegments = [.init(id: .max, source: source, text: "Текущая фраза \(number). Учитель продолжает…", isFinal: false)]
                    model.transcript = model.conversation.text
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    let expanded = source + " Puhumme koulusta."
                    model.conversation.apply(.init(revision: UInt64(number * 3 + 2), confirmed: [], provisional: expanded))
                    model.liveTranslationSegments = [.init(id: .max, source: expanded, text: "Текущая фраза \(number). Учитель продолжает обсуждение школьного расписания…", isFinal: false)]
                    model.transcript = model.conversation.text
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    let id = UInt64(242 + number), start = 57_600_000 + (number - 1) * 32_000
                    model.conversation.apply(.init(revision: UInt64(number * 3 + 3), confirmed: [.init(id: id, startSample: start, endSample: start + 32_000, text: source, state: .confirmed)], provisional: "", settledThroughSample: start + 32_000))
                    model.conversation.applyTranslations([.init(id: id, source: source, text: "Новая фраза \(number). Учитель продолжает обсуждение школьного расписания.", isFinal: true)])
                    model.liveTranslationSegments = []
                    model.transcript = model.conversation.text; model.translation = model.conversation.translatedText
                }
            }
        }
        .sheet(isPresented: $model.showAudioImport) { AudioImportView(model: model) }
    }
}

private actor LongConversationFixtureEngine: TextTranslationEngine {
    nonisolated func availableQualities(from: String, to: String) -> [ProcessingQuality] { ProcessingQuality.translationOptions(from: from, to: to) }
    var residentModelCount: Int { 0 }
    func prepare(from: String, to: String, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws { await onProgress(1) }
    func translate(_ text: String, from: String, to: String) async throws -> String { LongConversationHost.russian }
    func unload() async {}
}
