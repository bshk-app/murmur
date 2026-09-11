import SwiftUI
import MurmurCore

@MainActor @Observable final class AudioImportController {
    var jobs: [AudioImportJob] = []
    var activeID: UUID?
    var selectedID: UUID?
    var receiving = false
    var pausing = false
    var preparing = false
    var error: String?
    var receiveError: String?
    var receivingFilename: String?
    var fraction: Double = 0
    var busy: Bool { receiving || activeID != nil }
    func receive(_ url: URL, language: String, model: SpeechModelChoice) async {
        do { jobs.insert(try AudioImportJob.receive(url, language: language, model: model.rawValue), at: 0) }
        catch { self.error = error.localizedDescription }
    }
    func setLanguage(_ code: String, for id: UUID) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].language = code }
    }
    func start(_ id: UUID) { error = L10n.text("Speech engines are tested on a physical iPhone. This simulator only tests the interface.") }
    func pause() {
        guard ProcessInfo.processInfo.arguments.contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) == "listActionsFixture" }),
              let id = activeID, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = .paused; activeID = nil; preparing = false; pausing = false
    }
    func dismissCompleted() { jobs.removeAll { $0.canRetire } }
    func remove(_ id: UUID) { guard activeID != id else { return }; jobs.removeAll { $0.id == id } }
}
