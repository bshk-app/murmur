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
    @ObservationIgnored private var pauseIntent = AudioImportPauseIntent()
    @ObservationIgnored private var backgroundGrace: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var runStartedAt: Date?
    @ObservationIgnored private var runReadyAt: Date?
    /// Reported for every finished run so the phone can learn its own speed.
    @ObservationIgnored var onTiming: (@MainActor (_ audioSeconds: Double, _ decodeSeconds: Double, _ loadSeconds: Double) -> Void)?
    var fraction: Double = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private let repository = NoteRepository(directory: StoragePaths.notes)
    var busy: Bool { activeID != nil || receiving }
    /// Announced for a finished transcript, so a recording that came from
    /// somewhere else can be told how it ended.
    @ObservationIgnored var onFinished: (@MainActor (AudioImportJob) -> Void)?
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
    /// `allowBackground` is for a recording that arrived while the phone slept and
    /// is short enough to finish before the grace period runs out. Everything else
    /// still waits for someone to be looking at the screen.
    func start(_ id: UUID, allowBackground: Bool = false) {
        guard allowBackground || UIApplication.shared.applicationState == .active else { return }
        guard !receiving, let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status != .completed || jobs[i].text.isEmpty else { return }
        if activeID != nil {
            guard activeID != id, jobs[i].status != .queued else { return }
            // Queueing is as deliberate as starting, so it re-arms the same way.
            var queued = jobs[i]; queued.status = .queued; queued.queuedAt = Date(); queued.autoStart = true
            do { try queued.save(); jobs[i] = queued } catch { self.error = error.localizedDescription }
            return
        }
        if jobs[i].status == .completed { jobs[i].segments = [] }
        let previous = jobs[i]
        queueSuspended = false; jobs[i].queuedAt = nil
        let job = jobs[i]
        activeID = id; pausing = false; preparing = true; fraction = job.duration > 0 ? Double(job.completedThrough)/16_000/job.duration : 0
        // Starting deliberately re-arms the automatic resume a pause turned off.
        pauseIntent.started()
        runStartedAt = Date(); runReadyAt = nil
        jobs[i].status = .processing; jobs[i].error = nil; jobs[i].autoStart = true
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
            releaseBackgroundGrace()
            startNextQueued()
        }
    }
    private func startNextQueued() {
        let waiting = jobs.filter { $0.status == .queued }.map { AudioImportQueuePolicy.Waiting(id: $0.id, queuedAt: $0.queuedAt ?? $0.createdAt) }
        guard let next = AudioImportQueuePolicy.next(activeID: activeID, receiving: receiving, suspended: queueSuspended, foreground: UIApplication.shared.applicationState == .active, waiting: waiting) else { return }
        start(next)
    }
    private func ready() {
        runReadyAt = Date()
        preparing = false
    }

    /// The budget only becomes real once the assertion is held, so it is claimed
    /// before the estimate is weighed, and handed straight back if the answer is no.
    func claimBackgroundBudget() -> Double {
        guard activeID == nil else { return 0 }
        beginGrace()
        return UIApplication.shared.backgroundTimeRemaining
    }

    /// Awaits the running import, so a scheduled task can hold its slot until the
    /// work is actually done rather than reporting success the moment it starts.
    func waitForCompletion() async { await work?.value }

    func releaseUnusedBudget() {
        if activeID == nil { releaseBackgroundGrace() }
    }

    private func beginGrace() {
        guard backgroundGrace == .invalid else { return }
        backgroundGrace = UIApplication.shared.beginBackgroundTask(withName: "Audio import") { [weak self] in
            // Called on the main thread, and the assertion has to be given back
            // before this returns or the system kills the app outright.
            MainActor.assumeIsolated {
                self?.pause(userInitiated: false)
                self?.releaseBackgroundGrace()
            }
        }
    }
    /// Leaving the app no longer stops the work where it stands. A note from the
    /// watch is usually seconds from done, and iOS grants long enough to finish it
    /// and say so. The import pauses only when that runs out, which reads to the
    /// rest of the app exactly like leaving used to.
    func continueInBackground() {
        guard activeID != nil, backgroundGrace == .invalid else { pause(userInitiated: false); return }
        queueSuspended = true
        beginGrace()
    }

    /// An import that survived the trip was never really suspended, so the queue
    /// behind it must not stay blocked. Only an expiry leaves it suspended, and
    /// that path does not come through here.
    func returnedToForeground() {
        if activeID != nil { queueSuspended = false }
        releaseBackgroundGrace()
    }

    /// Held only while the app is away; in front there is nothing to extend.
    private func releaseBackgroundGrace() {
        guard backgroundGrace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundGrace)
        backgroundGrace = .invalid
    }

    /// Leaving the app pauses the same way a tap does, but only a tap means the
    /// user wants it stopped. A watch recording resumes by itself otherwise.
    /// The reason is recorded here and written in `finish`, after any checkpoint
    /// that was already in flight when the tap arrived.
    func pause(userInitiated: Bool = true) {
        queueSuspended = true
        guard activeID != nil else { return }
        pauseIntent.paused(userInitiated: userInitiated)
        pausing = true; work?.cancel()
    }
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
        // Decided last, so a checkpoint that raced the tap cannot undo it.
        if status == .paused { next.autoStart = pauseIntent.resumesAutomatically }
        try await saveNote(next); try next.save()
        if let current = jobs.firstIndex(where: { $0.id == id }) { jobs[current] = next }
        if status == .completed {
            fraction = 1
            if let runStartedAt, let runReadyAt {
                onTiming?(next.duration, Date().timeIntervalSince(runReadyAt), runReadyAt.timeIntervalSince(runStartedAt))
            }
            onFinished?(next)
        }
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
