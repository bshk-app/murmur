import SwiftUI
import MurmurCore
import MurmurSpeech

@MainActor @Observable final class AudioImportController {
    private(set) var jobs: [AudioImportJob] = []
    private(set) var activeID: UUID?
    private(set) var receiving = false
    private(set) var pausing = false
    private(set) var preparing = false
    var selectedID: UUID?
    var error: String?
    var receiveError: String?
    var receivingFilename: String?
    @ObservationIgnored private var queueSuspended = true
    var fraction: Double = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private let repository = NoteRepository(directory: StoragePaths.notes)
    var busy: Bool { activeID != nil || receiving }
    init() { reload() }
    func reload() {
        guard !busy else { return }
        do {
            jobs = try AudioImportJob.all()
            for i in jobs.indices where jobs[i].status == .processing {
                jobs[i].status = .paused; try jobs[i].save()
            }
        } catch { self.error = error.localizedDescription }
    }
    func dismissCompleted() {
        for job in jobs {
            do {
                if try job.retireIfCompleted() {
                    jobs.removeAll { $0.id == job.id }
                    if selectedID == job.id { selectedID = nil }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func receive(_ url: URL, language: String, model: SpeechModelChoice) async {
        guard !receiving else { return }
        receiving = true; receiveError = nil; receivingFilename = url.lastPathComponent
        defer { receiving = false; receivingFilename = nil; startNextQueued() }
        do {
            let job = try await Task.detached { try AudioImportJob.receive(url, language: language, model: model.rawValue) }.value
            try await saveNote(job)
            jobs.insert(job, at: 0); selectedID = job.id
        } catch { receiveError = error.localizedDescription }
    }
    func setLanguage(_ language: String, for id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), (jobs[i].segments.isEmpty || jobs[i].status == .completed && jobs[i].text.isEmpty), activeID != id else { return }
        jobs[i].language = language
        let current = SpeechModelChoice(rawValue: jobs[i].model) ?? .parakeet
        if !current.supports(language) { jobs[i].model = (language == "ar" ? SpeechModelChoice.cohereArabic : .parakeet).rawValue }
        do { try jobs[i].save() } catch { self.error = error.localizedDescription }
    }
    func start(_ id: UUID) {
        guard UIApplication.shared.applicationState == .active, !receiving, let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status != .completed || jobs[i].text.isEmpty else { return }
        if activeID != nil {
            guard activeID != id, jobs[i].status != .queued else { return }
            var queued = jobs[i]; queued.status = .queued; queued.queuedAt = Date()
            do { try queued.save(); jobs[i] = queued } catch { self.error = error.localizedDescription }
            return
        }
        if jobs[i].status == .completed { jobs[i].segments = [] }
        let previous = jobs[i]
        queueSuspended = false; jobs[i].queuedAt = nil
        let job = jobs[i]
        activeID = id; pausing = false; preparing = true; fraction = job.duration > 0 ? Double(job.completedThrough)/16_000/job.duration : 0
        jobs[i].status = .processing; jobs[i].error = nil
        do { try jobs[i].save() } catch { self.error = error.localizedDescription; jobs[i] = previous; activeID = nil; preparing = false; return }
        work = Task {
            let engine = AudioFileTranscriber(choice: SpeechModelChoice(rawValue: job.model) ?? .parakeet, modelsRoot: StoragePaths.models)
            do {
                try await engine.run(url: job.audioURL, language: job.language, completedThrough: job.completedThrough,
                    onReady: { [weak self] in await self?.ready() },
                    onProgress: { [weak self] seconds, total in
                        await self?.progress(id, seconds: seconds, total: total)
                    }, onSegment: { [weak self] segment, total in
                        guard let self else { throw CancellationError() }
                        try await self.commit(segment, for: id, duration: total)
                    })
                try await finish(id, status: .completed)
            } catch {
                let status: AudioImportJob.Status = Task.isCancelled ? .paused : .failed
                try? await finish(id, status: status, message: status == .failed ? error.localizedDescription : nil)
            }
            await engine.close()
            activeID = nil; work = nil; pausing = false; preparing = false
            startNextQueued()
        }
    }
    private func startNextQueued() {
        let waiting = jobs.filter { $0.status == .queued }.map { AudioImportQueuePolicy.Waiting(id: $0.id, queuedAt: $0.queuedAt ?? $0.createdAt) }
        guard let next = AudioImportQueuePolicy.next(activeID: activeID, receiving: receiving, suspended: queueSuspended, foreground: UIApplication.shared.applicationState == .active, waiting: waiting) else { return }
        start(next)
    }
    private func ready() { preparing = false }
    func pause() { queueSuspended = true; guard activeID != nil else { return }; pausing = true; work?.cancel() }
    private func progress(_ id: UUID, seconds: Double, total: Double) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].duration = total
        fraction = min(0.99, max(fraction, total > 0 ? seconds/total : 0))
    }
    private func commit(_ segment: AudioFileSegment, for id: UUID, duration: Double) async throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }), segment.startSample >= jobs[i].completedThrough else { throw CocoaError(.fileReadCorruptFile) }
        var next = jobs[i]; next.segments.append(segment); next.duration = duration
        // Persist the checkpoint before moving to the next batch. A restart may
        // re-decode the file, but never recognizes a committed range twice.
        try await saveNote(next)
        try next.save()
        if let current = jobs.firstIndex(where: { $0.id == id }) { jobs[current] = next }
    }
    private func finish(_ id: UUID, status: AudioImportJob.Status, message: String? = nil) async throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        var next = jobs[i]; next.status = status; next.error = message
        try await saveNote(next); try next.save()
        if let current = jobs.firstIndex(where: { $0.id == id }) { jobs[current] = next }
        if status == .completed { fraction = 1 }
    }
    private func saveNote(_ job: AudioImportJob) async throws {
        guard job.audio != nil || !job.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let previous = try await repository.note(job.id)
        var note = VoiceNote(id: job.id, createdAt: job.createdAt, text: job.text, sourceLanguage: job.language,
            duration: job.duration, model: "file · " + job.model)
        note.sourceFileName = job.filename; note.transcriptionComplete = job.status == .completed
        note.audio = job.audio ?? previous?.audio
        note.captureClosed = true
        note.utterances = job.segments.enumerated().map { index, segment in
            .init(id: UInt64(index + 1), startSample: segment.startSample, endSample: segment.endSample, text: segment.text, settled: true)
        }
        try await repository.saveTranscription(note, previousVersion: job.previousVersion)
    }
    func retranscribe(_ note: VoiceNote, model: SpeechModelChoice) throws {
        guard !busy, let audio = note.audio, FileManager.default.fileExists(atPath: try audio.url(in: StoragePaths.recordings).path) else { throw CocoaError(.fileNoSuchFile) }
        var job = AudioImportJob(filename: note.sourceFileName ?? note.title, storedFilename: audio.filename,
                                 language: note.sourceLanguage, model: model.rawValue)
        job.id = note.id; job.createdAt = note.createdAt; job.duration = note.duration
        job.audio = audio; job.previousVersion = TranscriptVersion(note: note)
        try job.save()
        jobs.removeAll { $0.id == note.id }; jobs.insert(job, at: 0); selectedID = job.id
    }
    func remove(_ id: UUID) async {
        guard activeID != id, let job = jobs.first(where: { $0.id == id }) else { return }
        do {
            try await saveNote(job)
            try FileManager.default.removeItem(at: job.directory); jobs.removeAll { $0.id == id }
        }
        catch { self.error = error.localizedDescription }
    }
}
