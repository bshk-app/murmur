#if DEBUG
import SwiftUI
import MurmurTranslation

struct EuropeanTranslationProbe: View {
    @State private var status = "Checking European translations"
    var body: some View {
        Text(status).padding().task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            let session = TranslationSession(modelsRoot: StoragePaths.translation)
            var output: [[String: Any]] = []
            var report: [String: Any] = [:]
            do {
                for (from, to, input) in [
                    ("en", "de", "I will send the documents tomorrow."),
                    ("de", "fr", "Ich schicke die Dokumente morgen."),
                    ("en", "pt", "I will send the documents tomorrow."),
                    ("en", "hr", "I will send the documents tomorrow."),
                    ("en", "mt", "I will send the documents tomorrow."),
                    ("mt", "ga", "Nibgħat id-dokumenti għada.")
                ] {
                    status = "Preparing \(from) → \(to)"
                    try await session.prepare(from: from, to: to) { progress in status = "\(from) → \(to): \(Int(progress.fraction * 100))%" }
                    try await session.warmUp(from: from, to: to)
                    let preview = try await session.preview(input, from: from, to: to)
                    let text = try await session.finish(input, from: from, to: to)
                    guard !text.isEmpty, text != input, !preview.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
                    await session.unload()
                    let remaining = await session.residentModelCount
                    guard remaining == 0 else { throw CocoaError(.validationMissingMandatoryProperty) }
                    output.append(["from": from, "to": to, "input": input, "preview": preview, "output": text, "residentAfterUnload": remaining])
                }
                report["passed"] = true; status = "European translation verified"
            } catch { report["error"] = error.localizedDescription; report["passed"] = false; status = error.localizedDescription }
            report["directions"] = output
            await session.unload()
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) {
                try? data.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("european-translation-probe.json"), options: .atomic)
            }
        }
    }
}
#endif
