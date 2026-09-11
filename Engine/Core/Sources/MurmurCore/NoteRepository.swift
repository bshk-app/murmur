import Foundation
import Darwin
import GRDB

/// Transactional storage shared by recording, imports and extensions.
/// List pages never decode full transcripts or their history.
public actor NoteRepository {
    private let directory: URL
    private var connection: DatabaseQueue?
    public init(directory: URL) { self.directory = directory }

    public func note(_ id: UUID) throws -> VoiceNote? {
        try database().read { try NoteDatabase.read(id.uuidString, db: $0) }
    }

    /// For exports and diagnostics. The application list uses page().
    public func all() throws -> [VoiceNote] {
        try database().read { db in
            try String.fetchAll(db, sql: "SELECT id FROM notes ORDER BY createdAt DESC, id DESC")
                .compactMap { try NoteDatabase.read($0, db: db) }
        }
    }

    public func page(after cursor: NotePage.Cursor? = nil, query: String = "", limit: Int = 50) throws -> NotePage {
        let count = min(200, max(1, limit))
        return try database().read { db in
            var conditions: [String] = []
            var arguments = StatementArguments()
            if let cursor {
                conditions.append("(createdAt < ? OR (createdAt = ? AND id < ?))")
                arguments += [cursor.createdAt, cursor.createdAt, cursor.id.uuidString]
            }
            if !query.isEmpty {
                // Preserve Unicode-aware substring search, including literal %/_.
                conditions.append("noteContains(CASE WHEN translation IS NULL OR translation = '' THEN text ELSE text || char(10) || char(10) || translation END, ?)")
                arguments += [query]
            }
            let filter = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
            arguments += [count + 1]
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, createdAt, title, substr(coalesce(translation, text), 1, 300) AS preview,
                       sourceLanguage, targetLanguage, transcriptionComplete
                FROM notes\(filter) ORDER BY createdAt DESC, id DESC LIMIT ?
                """, arguments: arguments)
            let items = try rows.prefix(count).map(NoteSummary.init(row:))
            return NotePage(items: items, next: rows.count > count ? items.last.map(NotePage.Cursor.init) : nil)
        }
    }

    public func hasAudioReference(_ recordingID: UUID) throws -> Bool {
        try database().read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM notes WHERE audioID = ?)", arguments: [recordingID.uuidString]) ?? false
        }
    }

    public func isDeleted(_ id: UUID) throws -> Bool {
        try database().read { try Self.isDeleted(id.uuidString, db: $0) }
    }

    public func incompleteRecordingIDs() throws -> [UUID] {
        try database().read { db in
            try String.fetchAll(db, sql: "SELECT id FROM notes WHERE transcriptionComplete = 0 AND audioIsMicrophone = 1")
                .compactMap(UUID.init(uuidString:))
        }
    }

    public func save(_ note: VoiceNote) throws {
        try database().write { db in
            try NoteDatabase.write(note, db: db)
            try db.execute(sql: "DELETE FROM deletedNotes WHERE id = ?", arguments: [note.id.uuidString])
        }
    }

    public func saveProgress(_ note: VoiceNote) throws {
        try database().write { db in
            guard try !Self.isDeleted(note.id.uuidString, db: db),
                  let stored = try NoteRecord.fetchOne(db, key: note.id.uuidString),
                  stored.transcriptionComplete != true, stored.captureClosed != true,
                  (note.captureRevision ?? 0) >= (stored.captureRevision.flatMap(UInt64.init) ?? 0) else { return }
            try NoteDatabase.write(note, db: db)
        }
    }

    public func saveTranscription(_ note: VoiceNote, previousVersion: TranscriptVersion?) throws {
        if previousVersion != nil && (note.transcriptionComplete != true || note.text.isEmpty) { return }
        try database().write { db in
            guard try !Self.isDeleted(note.id.uuidString, db: db) else { return }
            let stored = try NoteDatabase.read(note.id.uuidString, db: db)
            if previousVersion != nil && stored == nil { return }
            var result = note
            result.transcriptVersions = stored?.transcriptVersions
            if let previousVersion, !(result.transcriptVersions ?? []).contains(where: { $0.id == previousVersion.id }) {
                result.transcriptVersions = (result.transcriptVersions ?? []) + [previousVersion]
            }
            try NoteDatabase.write(result, db: db)
        }
    }

    public func delete(_ id: UUID) throws {
        try database().write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO deletedNotes (id) VALUES (?)", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id.uuidString])
        }
    }

    private static func isDeleted(_ id: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM deletedNotes WHERE id = ?)", arguments: [id]) ?? false
    }

    private func database() throws -> DatabaseQueue {
        if let connection { return connection }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        // Inherited by database/journals; permits background capture after first unlock.
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        var configuration = Configuration()
        configuration.busyMode = .timeout(10)
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction("noteContains", argumentCount: 2, pure: true) { values in
                guard let text = String.fromDatabaseValue(values[0]), let query = String.fromDatabaseValue(values[1]) else { return false }
                return text.localizedCaseInsensitiveContains(query)
            })
        }
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("notes.sqlite").path, configuration: configuration)
        try withMigrationLock {
            try NoteDatabase.migrate(queue)
        }
        connection = queue
        return queue
    }

    /// GRDB serializes writes; this also serializes schema inspection/migration
    /// across separate processes opening a brand-new App Group database together.
    private func withMigrationLock<T>(_ body: () throws -> T) throws -> T {
        let path = directory.appendingPathComponent(".notes-access.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
        #endif
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try body()
    }
}
