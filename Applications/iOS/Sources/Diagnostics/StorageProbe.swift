#if DEBUG
import SwiftUI
import MurmurCore
import MurmurSpeech

struct StorageProbe: View {
    @State private var status = "Checking model storage"
    @State private var available = ""
    var body: some View {
        VStack(spacing:16) { Text(status); Text(available).font(.footnote) }.padding().task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            var report: [String: Any] = [:]
            do {
                let live=ModelStorage(modelsRoot:StoragePaths.models,speech:SpeechAssets.storageLocations())
                let inventory=try await live.inventory()
                if let free=inventory.availableDiskBytes { available="Available on this iPhone: " + ByteCountFormatter.string(fromByteCount:free,countStyle:.file) }
                // Free-space API data stays on the device. Report only catalog
                // counts and the outcome of deletion in an isolated fixture.
                report["discoveredPackages"] = inventory.items.count
                report["speechPackages"] = inventory.items.filter { $0.kind == .speech || $0.kind == .importedSpeech }.count
                report["translationPackages"] = inventory.items.filter { $0.kind == .translationQuality || $0.kind == .translationPreview }.count
                let root=FileManager.default.temporaryDirectory.appendingPathComponent("StorageProbe-"+UUID().uuidString)
                defer { try? FileManager.default.removeItem(at:root) }
                let modelRoot=root.appendingPathComponent("Models")
                for name in ["ct2-rufi","ct2-enfi"] {
                    let dir=modelRoot.appendingPathComponent("TranslationModels").appendingPathComponent(name)
                    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                    try Data(repeating:1,count:131072).write(to:dir.appendingPathComponent("model.bin"))
                }
                let note=root.appendingPathComponent("note.json"), audio=root.appendingPathComponent("source.wav")
                let noteData=Data("fixture note".utf8), audioData=Data([1,2,3,4])
                try noteData.write(to:note);try audioData.write(to:audio)
                let fixture=ModelStorage(modelsRoot:modelRoot)
                let before=try await fixture.inventory()
                try await fixture.remove(id:"translation/ct2-rufi")
                let after=try await fixture.inventory()
                let protected = try Data(contentsOf:note) == noteData && Data(contentsOf:audio) == audioData
                let passed=before.items.count == 2 && after.items.count == 1 && after.items.first?.id == "translation/ct2-enfi" && protected
                report["fixtureDeletionPassed"] = passed
                report["fixtureNotesAndAudioPreserved"] = protected
                report["userModelFilesDeleted"] = false
                report["passed"] = passed
                status=passed ? "Storage verified" : "Storage verification failed"
            } catch { report["passed"] = false; report["error"] = error.localizedDescription; status=error.localizedDescription }
            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
                try? data.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("storage-probe.json"),options:.atomic)
            }
        }
    }
}
#endif
