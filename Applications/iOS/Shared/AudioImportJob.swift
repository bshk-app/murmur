import Foundation
import MurmurCore

struct AudioImportJob: Identifiable, Codable {
    enum Status: String, Codable { case pending, queued, processing, paused, completed, failed }
    enum Origin: String, Codable { case watch }
    var id = UUID()
    var createdAt = Date()
    var filename: String
    var storedFilename: String
    var language: String
    var model: String
    var status = Status.pending
    /// Absent for files the user handed over. Jobs written before the watch
    /// existed decode with both of these nil, which reads as "not from a watch,
    /// may start on its own".
    var origin: Origin?
    /// Cleared when the user pauses deliberately, so returning to the app does
    /// not restart what they stopped.
    var autoStart: Bool?
    var segments: [AudioFileSegment] = []
    var duration: Double = 0
    var error: String?
    var queuedAt: Date?
    var audio: RecordedAudio?
    var previousVersion: TranscriptVersion?
    var processedSeconds: Double { min(duration, Double(completedThrough) / 16_000) }
    var savedFraction: Double? {
        if status == .completed && !text.isEmpty { return 1 }
        guard duration > 0, !segments.isEmpty else { return nil }
        return min(0.99, processedSeconds / duration)
    }
    static func time(_ seconds: Double) -> String {
        let n = max(0, Int(seconds))
        return n >= 3600 ? String(format: "%d:%02d:%02d", n/3600, n/60%60, n%60) : String(format: "%d:%02d", n/60, n%60)
    }
    var completedThrough: Int { segments.last?.endSample ?? 0 }
    var text: String { segments.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n") }
    var directory: URL { Self.root.appendingPathComponent(id.uuidString) }
    var audioURL: URL {
        if let audio, let url = try? audio.url(in: StoragePaths.recordings) { return url }
        return directory.appendingPathComponent(storedFilename)
    }
    static var root: URL { StoragePaths.notes.appendingPathComponent("Imports") }
    func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        #if os(iOS)
        try data.write(to: directory.appendingPathComponent("job.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: directory.appendingPathComponent("job.json"), options: .atomic)
        #endif
    }
    /// A successful import has already saved its note; only its temporary job remains.
    var canRetire: Bool { status == .completed && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func retireIfCompleted() throws -> Bool {
        guard canRetire, audio != nil || !FileManager.default.fileExists(atPath: audioURL.path) else { return false }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        return true
    }
    static func all() throws -> [Self] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap {
            try? JSONDecoder().decode(Self.self, from: Data(contentsOf: $0.appendingPathComponent("job.json")))
        }.filter { try !$0.retireIfCompleted() }.sorted { $0.createdAt > $1.createdAt }
    }
    /// The source belongs to Voice Memos/Files, or to the watch staging folder.
    /// Only a coordinated private copy is retained, and its security scope remains
    /// open until the copy finishes.
    static func receive(_ url: URL, language: String, model: String) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
        let sourceDirectory = url.deletingLastPathComponent().standardizedFileURL
        let fromWatch = sourceDirectory == StoragePaths.watchInbox.standardizedFileURL
        var job = Self(filename: url.lastPathComponent, storedFilename: "source." + ext, language: language, model: model)
        job.origin = fromWatch ? .watch : nil
        job.audio = RecordedAudio(recordingID: job.id, filename: "original." + ext, isMicrophoneRecording: false)
        try FileManager.default.createDirectory(at: job.directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: job.audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            var coordinationError: NSError?, copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
                do {
                    guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                    try FileManager.default.copyItem(at: source, to: job.audioURL)
                }
                catch { copyError = error }
            }
            if let error = coordinationError ?? copyError as NSError? { throw error }
            try job.save()
            // Open-In may supply a system copy in this app's Documents/Inbox, and
            // the watch bridge stages its own copy. Consume either only after our
            // durable job exists; external provider files and the Voice Memos
            // original are never removed. A crash before this leaves the staged
            // file for the next sweep instead of losing the recording.
            let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox").standardizedFileURL
            if sourceDirectory == inbox || fromWatch {
                try FileManager.default.removeItem(at: url)
            }
            return job
        } catch {
            try? FileManager.default.removeItem(at: job.directory)
            try? FileManager.default.removeItem(at: job.audioURL.deletingLastPathComponent())
            throw error
        }
    }
}
