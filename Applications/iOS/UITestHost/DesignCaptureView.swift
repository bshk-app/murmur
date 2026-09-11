import SwiftUI
import WidgetKit
import MurmurCore

/// Deterministic design handoff fixtures, compiled only in MurMurUITestHost.
/// Captures are state illustrations, not claims about running inference.
struct DesignCaptureView: View {
    @State private var model = AppModel()
    @State private var screen = "notes"
    @State private var dark = false
    @State private var generation = UUID()
    private let screens = ["notes", "audio-ready", "audio-receive-error", "audio-receiving", "audio-preparing", "audio-progress", "audio-pausing", "audio-paused", "audio-complete", "audio-error", "audio-silent", "audio-queue", "note-partial", "note-complete", "memory-empty", "memory-loaded", "memory-busy", "settings", "languages", "translate", "keyboard-setup", "keyboard-preparing", "keyboard-ready", "keyboard-activate", "keyboard-load", "keyboard-hold", "keyboard-listening", "keyboard-result", "widgets"]
    private var accessibility: Bool { ProcessInfo.processInfo.arguments.contains("--capture-accessibility") }
    private var language: String { Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en" }
    private func text(_ ru: String, _ en: String) -> String { language == "ru" ? ru : en }
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--store-capture") { StoreCaptureView() }
        else { designContent }
    }
    private var designContent: some View {
        ZStack {
        Group {
            if ["keyboard-activate", "keyboard-load", "keyboard-hold", "keyboard-listening", "keyboard-result"].contains(screen) {
                KeyboardDesignHost(state: model.keyboard.state, caption: text("Пример поля другого приложения", "Example field in another app"))
            } else if screen == "widgets" { WidgetPreviewView() }
            else { NotesView(model: model) }
        }.id(generation)
        }.environment(\.dynamicTypeSize, accessibility ? .accessibility2 : .large).environment(\.colorScheme, dark ? .dark : .light).preferredColorScheme(dark ? .dark : .light).task { await captureAll() }
    }
    @MainActor private func captureAll() async {
        UIApplication.shared.isIdleTimerDisabled = true
        UserDefaults.standard.set("system", forKey: "appearance")
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        UserDefaults.standard.set(3, forKey: "onboardingVersion")
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DesignCapture-" + language + (accessibility ? "-accessibility" : ""))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("complete.txt"))
        let requested = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-screens=") })?.replacingOccurrences(of: "--capture-screens=", with: "").split(separator: ",").map(String.init)
        let captureScreens = requested ?? (accessibility ? ["audio-ready", "audio-progress", "memory-loaded"] : screens)
        let themes = accessibility ? [false] : ProcessInfo.processInfo.arguments.contains("--capture-dark-only") ? [true] : [false, true]
        for theme in themes {
            for name in captureScreens {
                if name == "widgets" && theme { continue } // Current widgets have a fixed dark surface.
                UIApplication.shared.isIdleTimerDisabled = true
                UserDefaults.standard.set(theme ? "dark" : "light", forKey: "appearance")
                for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                    for window in scene.windows {
                        window.overrideUserInterfaceStyle = theme ? .dark : .light
                        window.traitOverrides.preferredContentSizeCategory = accessibility ? .accessibilityLarge : .large
                    }
                }
                UserDefaults.standard.set(name == "translate" ? "voice" : "text", forKey: "translationInputMode")
                screen = name; dark = theme; model = fixture(name); generation = UUID()
                var textWork: Task<Void, Never>?
                if ["translate-text-result", "translate-text-error", "translate-text-preparing", "translate-text-running", "translate-text-cancelling", "translate-text-swapped", "memory-text"].contains(name) {
                    textWork = model.textTranslator.start()
                    if ["translate-text-result", "translate-text-error", "translate-text-swapped", "memory-text"].contains(name) { await textWork?.value }
                    if name == "translate-text-swapped" { model.textTranslator.swap() }
                    if name == "translate-text-cancelling" { try? await Task.sleep(for: .milliseconds(100)); model.textTranslator.cancel() }
                }
                try? await Task.sleep(for: .milliseconds(650))
                switch name {
                case let value where value.hasPrefix("audio-"): model.showAudioImport = true
                case let value where value.hasPrefix("memory-"): model.showMemory = true
                case let value where value.hasPrefix("storage-"): model.showStorage = true
                case "settings": model.showSettings = true
                case "languages": model.showLanguages = true
                case let value where value == "translate" || value.hasPrefix("translate-text"): model.showTranslation = true
                case "keyboard-setup", "keyboard-preparing", "keyboard-ready": model.showKeyboardSetup = true
                case "note-partial", "note-complete": model.selectedNote = model.notes.first
                default: break
                }
                try? await Task.sleep(for: .milliseconds(850))
                guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { continue }
                window.rootViewController?.presentedViewController?.traitOverrides.preferredContentSizeCategory = accessibility ? .accessibilityLarge : .large
                try? await Task.sleep(for: .milliseconds(250))
                if name.hasPrefix("memory-") {
                    window.rootViewController?.presentedViewController?.sheetPresentationController?.selectedDetentIdentifier = .large
                    try? await Task.sleep(for: .milliseconds(450))
                }
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let png = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }.pngData()
                try? png?.write(to: folder.appendingPathComponent(name + (theme ? "-dark" : "-light") + ".png"), options: .atomic)
                model.textTranslator.cancel(); await model.textTranslationEngine.release(); await textWork?.value
                // Tear down presented sheets before replacing their root model.
                model.showAudioImport = false; model.showMemory = false; model.showStorage = false; model.showLanguages = false
                model.showTranslation = false; model.showKeyboardSetup = false
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        if !accessibility {
            for family in [WidgetFamily.systemSmall, .systemMedium] {
                let entry = MurMurEntry(date: .now, state: .init(source: "ru", target: "fi", status: "Inactive"))
                let view = MurMurControlsContent(entry: entry, family: family).padding(16)
                    .frame(width: family == .systemSmall ? 170 : 360, height: 170)
                    .background(Color(red: 0.10, green: 0.08, blue: 0.065), in: RoundedRectangle(cornerRadius: 24))
                    .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: view); renderer.scale = 3
                try? renderer.uiImage?.pngData()?.write(to: folder.appendingPathComponent(family == .systemSmall ? "widget-small.png" : "widget-medium.png"))
            }
        }
        try? Data("complete".utf8).write(to: folder.appendingPathComponent("complete.txt"))
        UIApplication.shared.isIdleTimerDisabled = false
    }
    @MainActor private func fixture(_ name: String) -> AppModel {
        let scenario: UIHostTextTranslationEngine.Scenario = name == "translate-text-preparing" ? .preparing : ["translate-text-running", "translate-text-cancelling"].contains(name) ? .translating : name == "translate-text-error" ? .failure : .success
        let m = AppModel(textScenario: scenario)
        m.source = language == "ru" ? "ru" : "en"; m.target = "fi"; m.speechModel = m.source == "ru" ? .gigaam : .parakeet
        let copy = text("Обсудили план на следующую неделю. Подготовим короткий прототип и проверим его на встрече.\n\nЯ соберу замечания команды и отправлю обновлённый вариант в четверг.\n\nОтдельно проверим удобство импорта и понятность статусов обработки.", "We discussed the plan for next week. We will prepare a small prototype and review it together.\n\nI will collect the team's feedback and send an updated version on Thursday.\n\nWe will also check the import flow and whether processing statuses are clear.")
        var job = AudioImportJob(filename: text("Встреча команды.m4a", "Team meeting.m4a"), storedFilename: "design-only.m4a", language: m.source, model: m.speechModel.rawValue)
        job.createdAt = Date(timeIntervalSince1970: 1_788_772_800); job.duration = 3_600
        let partial = AudioFileSegment(startSample: 0, endSample: 24*60*16_000, text: copy)
        if ["audio-progress", "audio-pausing", "audio-paused", "audio-complete", "audio-queue", "note-partial", "note-complete", "notes"].contains(name) { job.segments = [partial] }
        if ["audio-preparing", "audio-progress", "audio-pausing"].contains(name) {
            job.status = .processing; m.audioImports.activeID = job.id
            m.audioImports.preparing = name == "audio-preparing"; m.audioImports.pausing = name == "audio-pausing"
            m.audioImports.fraction = name == "audio-preparing" ? 0 : 0.4
        }
        if ["audio-paused", "audio-queue", "note-partial", "notes"].contains(name) { job.status = .paused }
        if ["audio-complete", "audio-silent", "note-complete"].contains(name) { job.status = .completed }
        if name == "audio-error" { job.status = .failed; job.error = text("Не удалось прочитать аудиофайл. Попробуйте экспортировать запись ещё раз.", "The audio file could not be read. Try exporting the recording again.") }
        m.audioImports.jobs = [job]
        if name == "audio-receiving" { m.audioImports.jobs = []; m.audioImports.receiving = true; m.audioImports.receivingFilename = job.filename }
        if name == "audio-receive-error" { m.audioImports.jobs = []; m.audioImports.receiveError = text("Не удалось скопировать файл.", "The file could not be copied.") }
        if name == "audio-queue" {
            m.audioImports.jobs[0].status = .processing; m.audioImports.activeID = job.id
            var queued = AudioImportJob(filename: text("Идея для проекта.wav", "Project idea.wav"), storedFilename: "design-only.wav", language: "en", model: "parakeet")
            queued.status = .queued; queued.queuedAt = Date(); m.audioImports.jobs.append(queued)
        }
        var note = VoiceNote(id: job.id, createdAt: job.createdAt, text: copy, sourceLanguage: m.source, duration: 3_600, model: "design fixture")
        note.sourceFileName = job.filename; note.transcriptionComplete = name != "note-partial" && name != "notes"
        m.notes = [note]
        if name == "memory-loaded" { m.designLoadedModels = true; m.modelReady = true }
        if name == "memory-busy" { m.designLoadedModels = true; m.phase = .preparing }
        m.languageLibrary.speech = ["ru", "fi", "en"]
        m.languageLibrary.translations = [.init(source: "ru", target: "fi"), .init(source: "en", target: "ga")]
        m.languageLibrary.markPrepared("speech:ru"); m.languageLibrary.markPrepared("translation:ru-fi")
        m.keyboard.configuration = .init(source: m.source, target: "fi")
        var state = KeyboardSessionState(configuration: m.keyboard.configuration)
        if ["keyboard-preparing", "keyboard-load"].contains(name) {
            state.phase = .preparing; state.microphoneActive = true
            state.preparationDetail = L10n.text("Preparing dictation…")
            m.keyboard.isActive = true; m.keyboard.detail = L10n.text("Preparing dictation…")
        }
        if ["keyboard-ready", "keyboard-hold", "keyboard-listening", "keyboard-result"].contains(name) {
            state.phase = name == "keyboard-listening" ? .recording : name == "keyboard-result" ? .result : .ready
            state.microphoneActive = true; m.keyboard.isActive = true
            m.keyboard.detail = L10n.text("Return to your app and hold the microphone on the Murmator keyboard.")
        }
        if name == "keyboard-listening" || name == "keyboard-result" {
            state.utteranceID = UUID(); state.text = text("Отправлю документы завтра.", "I will send the documents tomorrow.")
            state.translation = "Lähetän asiakirjat huomenna."
        }
        m.keyboard.state = state
        if name.hasPrefix("translate-text-") || name == "memory-text" { m.textTranslator.input = text("Отправлю документы завтра.\n\nМожем встретиться в три часа?", "I will send the documents tomorrow.\n\nCan we meet at three?") }
        if name == "translate-text-limit" { m.textTranslator.input = String(repeating: text("Пример длинного текста. ", "Example of a long text. "), count: 480) }
        if name.hasPrefix("storage-") && name != "storage-empty" {
            let items: [ModelStorageItem] = name == "storage-speech" ? [
                .init(id:"speech/russian-accurate", kind:.speech, title:"Russian speech recognition", detail:"Used for Russian dictation and audio imports.", bytes:480_000_000),
                .init(id:"speech/multilingual-accurate", kind:.speech, title:"Multilingual speech recognition", detail:"Shared by several dictation languages and keyboard sessions.", bytes:360_000_000)
            ] : [
                .init(id:"translation/ct2-rufi", kind:.translationQuality, title:"Translation", detail:"A direction may also be used by translations through an intermediate language.", source:"ru",target:"fi",bytes:253_000_000),
                .init(id:"translation/moz-ruen", kind:.translationPreview, title:"Live translation preview", detail:"A direction may also be used by translations through an intermediate language.", source:"ru",target:"en",bytes:23_000_000)
            ]
            m.storageInventory = .init(items:items,totalBytes:items.reduce(0){$0+$1.bytes},availableDiskBytes:42_000_000_000)
            if name == "storage-busy" { m.keyboard.hasPendingPreparation = true }
        }
        if name == "notes-clean" || name == "audio-empty" { m.audioImports.jobs = [] }
        m.textTranslator.setSource(language == "ru" ? "ru" : "en"); m.textTranslator.setTarget("fi")
        return m
    }
}

private struct KeyboardDesignHost: View {
    let state: KeyboardSessionState
    let caption: String
    var body: some View {
        VStack(spacing: 0) {
            Text(caption).font(.footnote).foregroundStyle(.secondary).padding(.top, 30)
            Spacer()
            Text("…").frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.quaternary, in: RoundedRectangle(cornerRadius: 14)).padding()
            KeyboardDesignController(state: state).frame(height: state.phase == .result ? 430 : 350)
        }.background(Color(.systemBackground))
    }
}
private struct KeyboardDesignController: UIViewControllerRepresentable {
    let state: KeyboardSessionState
    func makeUIViewController(context: Context) -> KeyboardViewController { let c = KeyboardViewController(); c.setDesignSnapshot(state); return c }
    func updateUIViewController(_ controller: KeyboardViewController, context: Context) { controller.setDesignSnapshot(state) }
}
