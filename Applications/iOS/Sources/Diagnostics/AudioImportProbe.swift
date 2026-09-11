#if DEBUG
import SwiftUI
import MurmurCore

struct AudioImportProbe: View {
    @State private var status = "Checking audio-file import"
    var body: some View {
        Text(status).padding().task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let source = docs.appendingPathComponent("ASRCorpus/ru_ru-1642196827911660403.wav")
            let controller = AudioImportController()
            var report: [String: Any] = [:]
            await controller.receive(source, language: "ru", model: .gigaam)
            if let id = controller.selectedID {
                controller.start(id)
                while controller.activeID != nil {
                    status = "\(Int(controller.fraction * 100))%"
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if let job = controller.jobs.first(where: { $0.id == id }) {
                    let repository = NoteRepository(directory: StoragePaths.notes)
                    let saved = try? await repository.all().first { $0.id == id }
                    report = ["completed": job.status == .completed, "text": job.text,
                              "batches": job.segments.count, "duration": job.duration,
                              "originalPreserved": FileManager.default.fileExists(atPath: source.path),
                              "audioRetained": FileManager.default.fileExists(atPath: job.audioURL.path),
                              "noteSaved": saved?.transcriptionComplete == true,
                              "error": job.error ?? ""]
                    report["passed"] = job.status == .completed && job.text.contains("каналов") && saved?.transcriptionComplete == true && saved?.audio != nil && FileManager.default.fileExists(atPath: job.audioURL.path)
                    // Only the note/job this probe just created.
                    await controller.remove(id)
                    try? await repository.delete(id)
                    if let audio = saved?.audio, let url = try? audio.url(in: StoragePaths.recordings) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                }
            } else { report["error"] = controller.error ?? "Import did not create a job"; report["passed"] = false }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) {
                try? data.write(to: docs.appendingPathComponent("audio-import-probe.json"), options: .atomic)
            }
            status = report["passed"] as? Bool == true ? "Audio import verified" : "Audio import verification failed"
        }
    }
}
#endif
