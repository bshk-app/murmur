#if DEBUG
import SwiftUI
import MurmurCore
import MurmurTranslation
import AVFoundation

struct TextTranslationProbe: View {
    @State private var status = "Checking text translation"
    var body: some View {
        Text(status).padding().task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            let repository = NoteRepository(directory: StoragePaths.notes)
            let before = try? await repository.all()
            let permission = AVAudioApplication.shared.recordPermission
            var rows: [[String: Any]] = [], passed = true
            for (from, to, input) in [
                ("en", "de", "I will send the documents tomorrow.\n\nCan we meet at three?"),
                ("de", "fr", "Ich schicke die Dokumente morgen.\n\nKönnen wir uns um drei treffen?")
            ] {
                status = "Translating \(from) → \(to)"
                let engine = TextTranslationSession(modelsRoot: StoragePaths.translation)
                let model = TextTranslationModel(engine: engine, source: from, target: to,
                    availableTargets: { TextTranslationSession.availableTargets(from: $0, modelsRoot: StoragePaths.translation) })
                model.input = input
                await model.start()?.value
                let correct = model.error == nil && !model.output.isEmpty && model.output != input && model.output.contains("\n") && model.input == input && !model.isBusy
                await model.unload()
                let resident = await engine.residentModelCount
                rows.append(["from": from, "to": to, "output": model.output, "passed": correct && resident == 0, "error": model.error ?? "", "residentAfterUnload": resident])
                passed = passed && correct && resident == 0
            }
            let after = try? await repository.all()
            let notesUnchanged = before != nil && before == after
            let microphoneUnchanged = permission == AVAudioApplication.shared.recordPermission
            passed = passed && notesUnchanged && microphoneUnchanged
            let report: [String: Any] = ["passed": passed, "directions": rows, "notesUnchanged": notesUnchanged, "microphonePermissionUnchanged": microphoneUnchanged]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) {
                try? data.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("text-translation-probe.json"), options: .atomic)
            }
            status = passed ? "Text translation verified" : "Text translation verification failed"
        }
    }
}
#endif
