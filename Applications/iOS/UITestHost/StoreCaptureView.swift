import SwiftUI
import MurmurCore

/// App Store photography using production views and explicitly staged sample data.
/// This file belongs only to the UI test host. It does not run or benchmark inference.
struct StoreCaptureView: View {
    private struct Copy: Decodable {
        let locale: String
        let source: String
        let target: String
        let notes: [String]
        let detail: String
        let recording: String
        let translationInput: String
        let translationOutput: String
        let audioFilename: String
    }
    @State private var model = AppModel()
    @State private var generation = UUID()
    @State private var dark = false
    @State private var captureError: String?

    var body: some View {
        ZStack { NotesView(model: model).id(generation) }
            .environment(\.dynamicTypeSize, .large)
            .environment(\.colorScheme, dark ? .dark : .light)
            .preferredColorScheme(dark ? .dark : .light)
            .overlay { if let captureError { Text(captureError).padding().background(.red) } }
            .task { await capture() }
    }

    @MainActor private func capture() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let copy = try JSONDecoder().decode(Copy.self, from: Data(contentsOf: documents.appendingPathComponent("store-capture.json")))
            let folder = documents.appendingPathComponent("AppStoreCapture-" + copy.locale)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let finished = folder.appendingPathComponent("complete.json")
            if FileManager.default.fileExists(atPath: finished.path) { try FileManager.default.removeItem(at: finished) }
            UserDefaults.standard.set(true, forKey: "onboardingComplete")
            UserDefaults.standard.set(3, forKey: "onboardingVersion")
            UserDefaults.standard.set("text", forKey: "translationInputMode")
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            let scenes = ["01-notes", "02-dictation", "03-translation", "04-note", "05-audio", "06-languages"]
            var captures: [[String: Any]] = []
            for name in scenes {
                dark = ["02-dictation", "05-audio"].contains(name)
                UserDefaults.standard.set(dark ? "dark" : "light", forKey: "appearance")
                model = fixture(copy, name: name)
                generation = UUID()
                try await Task.sleep(for: .milliseconds(700))
                switch name {
                case "02-dictation": model.showRecorder = true
                case "03-translation":
                    await model.textTranslator.start()?.value
                    model.showTranslation = true
                case "04-note": model.selectedNote = model.notes.first
                case "05-audio": model.showAudioImport = true
                case "06-languages": model.showLanguages = true
                default: break
                }
                try await Task.sleep(for: .milliseconds(1100))
                guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { throw CocoaError(.fileNoSuchFile) }
                window.overrideUserInterfaceStyle = dark ? .dark : .light
                window.rootViewController?.presentedViewController?.overrideUserInterfaceStyle = dark ? .dark : .light
                try await Task.sleep(for: .milliseconds(300))
                let format = UIGraphicsImageRendererFormat()
                format.scale = window.screen.scale
                format.opaque = true
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                guard let png = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
                captures.append(["file": name + ".png", "width": Int(image.size.width * image.scale), "height": Int(image.size.height * image.scale), "appearance": dark ? "dark" : "light"])
                model.showRecorder = false; model.showTranslation = false; model.showAudioImport = false
                model.showLanguages = false; model.selectedNote = nil
                model.textTranslator.cancel()
                await model.textTranslationEngine.release()
                try await Task.sleep(for: .milliseconds(500))
            }
            let report: [String: Any] = ["locale": copy.locale, "source": "Production SwiftUI views in the isolated UI test host", "data": "Staged sample notes and translation; no user data or inference measurement", "captures": captures]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: finished, options: .atomic)
        } catch { captureError = error.localizedDescription }
    }

    @MainActor private func fixture(_ copy: Copy, name: String) -> AppModel {
        let m = AppModel(textResult: copy.translationOutput)
        m.source = copy.source; m.target = copy.target
        m.speechModel = copy.source == "ru" ? .gigaam : .parakeet
        m.modelReady = true
        let date = Date(timeIntervalSince1970: 1_788_854_400)
        m.notes = copy.notes.enumerated().map { offset, text in
            VoiceNote(createdAt: date.addingTimeInterval(Double(-offset * 3600)), text: text,
                      sourceLanguage: copy.source, duration: Double([34, 18, 26][offset % 3]), model: m.speechModel.rawValue)
        }
        if name == "04-note" {
            m.notes = [VoiceNote(createdAt: date, text: copy.detail, sourceLanguage: copy.source, duration: 52, model: m.speechModel.rawValue)]
        }
        if name == "02-dictation" {
            m.phase = .recording; m.duration = 18
            m.transcript = copy.recording
            m.captionDisplay.finish(copy.recording)
            m.levels = (0..<42).map { CGFloat(0.12 + abs(sin(Double($0) * 0.7)) * 0.8) }
            m.detail = L10n.text("Listening…")
        }
        if name == "05-audio" {
            var job = AudioImportJob(filename: copy.audioFilename, storedFilename: "sample-audio.m4a", language: copy.source, model: m.speechModel.rawValue)
            job.createdAt = date; job.duration = 186; job.status = .completed
            job.segments = [.init(startSample: 0, endSample: 186 * 16_000, text: copy.detail)]
            m.audioImports.jobs = [job]
            m.notes = [VoiceNote(id: job.id, createdAt: date, text: copy.detail, sourceLanguage: copy.source, duration: 186, model: m.speechModel.rawValue)]
        }
        m.languageLibrary.speech = Array(Set([copy.source, "en", "fi", "de"])).sorted()
        m.languageLibrary.translations = [.init(source: copy.source, target: copy.target), .init(source: "en", target: "fr")]
        for language in m.languageLibrary.speech { m.languageLibrary.markPrepared("speech:" + language) }
        for pair in m.languageLibrary.translations { m.languageLibrary.markPrepared("translation:" + pair.id) }
        m.textTranslator.setSource(copy.source); m.textTranslator.setTarget(copy.target)
        m.textTranslator.input = copy.translationInput
        return m
    }
}
