#if DEBUG
import SwiftUI
import MurmurTranslation

/// Exercises the same downloadable packs and session lifecycle as production.
struct FinnishTranslationProbe: View {
    @State private var status = "Preparing Finnish verification"
    var body: some View {
        Text(status).padding().task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            let session = TranslationSession(modelsRoot: StoragePaths.translation)
            var rows: [[String: Any]] = []
            var report: [String: Any] = [:]
            do {
                for (from, to, input) in [("ru", "fi", "Я пришлю документы завтра."), ("fi", "ru", "Lähetän asiakirjat huomenna."), ("en", "fi", "I will send the documents tomorrow."), ("fi", "en", "Lähetän asiakirjat huomenna.")] {
                    status = "Downloading \(from) → \(to)"
                    try await session.prepare(from: from, to: to) { progress in status = "\(from) → \(to): \(Int(progress.fraction * 100))%" }
                    try await session.warmUp(from: from, to: to)
                    let output = try await session.finish(input, from: from, to: to)
                    let before = await session.residentModelCount
                    await session.unload()
                    let after = await session.residentModelCount
                    guard !output.isEmpty, output != input, before > 0, after == 0 else { throw CocoaError(.validationMissingMandatoryProperty) }
                    rows.append(["from": from, "to": to, "input": input, "output": output, "residentBeforeUnload": before, "residentAfterUnload": after])
                }
                status = "Checking keyboard model unload and reload"
                let app = AppModel()
                await app.enableKeyboard()
                let wasReady = app.keyboard.state.phase == .ready
                await app.releaseModels()
                let unloaded = !app.hasLoadedModels && !app.keyboard.isActive && !app.keyboard.state.microphoneActive
                await app.enableKeyboard()
                let reloaded = app.keyboard.state.phase == .ready
                await app.releaseModels()
                report["keyboardLifecycle"] = ["readyBeforeUnload": wasReady, "unloaded": unloaded, "readyAfterReload": reloaded]
                guard wasReady && unloaded && reloaded else { throw CocoaError(.validationMissingMandatoryProperty) }
                report["passed"] = true; status = "Finnish translation and unload verified"
            } catch { report["error"] = error.localizedDescription; report["passed"] = false; status = error.localizedDescription }
            report["directions"] = rows
            await session.unload()
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("finnish-translation-probe.json")
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}
#endif
