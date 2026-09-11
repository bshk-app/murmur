import Foundation
import GRDB

/// Explicit columns keep list queries independent of large transcripts/history.
/// IDs are globally unique strings; no extra UNIQUE constraints prevent a future
/// SQLiteData sync layer from being added to these tables.
enum NoteDatabase {
    static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("notes-v1") { db in
            try db.execute(sql: """
                CREATE TABLE notes (
                    id TEXT PRIMARY KEY NOT NULL,
                    createdAt DOUBLE NOT NULL,
                    title TEXT NOT NULL,
                    text TEXT NOT NULL,
                    translation TEXT,
                    sourceLanguage TEXT NOT NULL,
                    targetLanguage TEXT,
                    duration DOUBLE NOT NULL,
                    model TEXT NOT NULL,
                    sourceFileName TEXT,
                    transcriptionComplete BOOLEAN,
                    translationNeedsUpdate BOOLEAN,
                    translationIncomplete BOOLEAN,
                    captureRevision TEXT,
                    captureClosed BOOLEAN,
                    audioID TEXT,
                    audioFilename TEXT,
                    audioIsMicrophone BOOLEAN,
                    hasUtterances BOOLEAN NOT NULL,
                    hasVersions BOOLEAN NOT NULL
                );
                CREATE INDEX notesCreatedAt ON notes(createdAt DESC, id DESC);
                CREATE INDEX notesAudio ON notes(audioID);
                CREATE INDEX notesIncomplete ON notes(transcriptionComplete, audioIsMicrophone);
                CREATE TABLE transcriptVersions (
                    id TEXT PRIMARY KEY NOT NULL,
                    noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    savedAt DOUBLE NOT NULL,
                    text TEXT NOT NULL,
                    translation TEXT,
                    sourceLanguage TEXT NOT NULL,
                    targetLanguage TEXT,
                    hasUtterances BOOLEAN NOT NULL
                );
                CREATE INDEX versionsNote ON transcriptVersions(noteID);
                CREATE TABLE utterances (
                    id TEXT PRIMARY KEY NOT NULL,
                    noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                    versionID TEXT REFERENCES transcriptVersions(id) ON DELETE CASCADE,
                    localID TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    startSample INTEGER NOT NULL,
                    endSample INTEGER NOT NULL,
                    text TEXT NOT NULL,
                    translation TEXT,
                    settled BOOLEAN NOT NULL,
                    translationFailed BOOLEAN
                );
                CREATE INDEX utterancesNote ON utterances(noteID, versionID, position);
                CREATE INDEX utterancesVersion ON utterances(versionID);
                CREATE TABLE deletedNotes (id TEXT PRIMARY KEY NOT NULL);
                """)
        }
        try migrator.migrate(queue)
    }

    static func read(_ id: String, db: Database) throws -> VoiceNote? {
        guard let record = try NoteRecord.fetchOne(db, key: id) else { return nil }
        var note = try record.note()
        if record.hasUtterances {
            note.utterances = try UtteranceRecord.filter(Column("noteID") == id && Column("versionID") == nil)
                .order(Column("position")).fetchAll(db).map { try $0.utterance() }
        }
        if record.hasVersions {
            note.transcriptVersions = try VersionRecord.filter(Column("noteID") == id)
                .order(Column("position")).fetchAll(db).map { version in
                    var snapshot = VoiceNote(text: version.text, translation: version.translation,
                        sourceLanguage: version.sourceLanguage, targetLanguage: version.targetLanguage,
                        duration: 0, model: "")
                    if version.hasUtterances {
                        snapshot.utterances = try UtteranceRecord.filter(Column("versionID") == version.id)
                            .order(Column("position")).fetchAll(db).map { try $0.utterance() }
                    }
                    return TranscriptVersion(note: snapshot, id: try uuid(version.id), savedAt: Date(timeIntervalSinceReferenceDate: version.savedAt))
                }
        }
        return note
    }

    static func write(_ note: VoiceNote, db: Database) throws {
        try NoteRecord(note).upsert(db)
        let id = note.id.uuidString
        let versions = (note.transcriptVersions ?? []).enumerated().map { VersionRecord($0.element, noteID: id, position: $0.offset) }
        let existingVersions = try VersionRecord.filter(Column("noteID") == id).fetchAll(db)
        let versionIDs = Set(versions.map(\.id))
        for old in existingVersions where !versionIDs.contains(old.id) { try old.delete(db) }
        let oldVersions = Dictionary(uniqueKeysWithValues: existingVersions.map { ($0.id, $0) })
        for version in versions where oldVersions[version.id] != version { try version.upsert(db) }

        var utterances = (note.utterances ?? []).enumerated().map {
            UtteranceRecord($0.element, noteID: id, versionID: nil, position: $0.offset)
        }
        for version in note.transcriptVersions ?? [] {
            utterances += (version.utterances ?? []).enumerated().map {
                UtteranceRecord($0.element, noteID: id, versionID: version.id.uuidString, position: $0.offset)
            }
        }
        let existing = try UtteranceRecord.filter(Column("noteID") == id).fetchAll(db)
        let ids = Set(utterances.map(\.id))
        for old in existing where !ids.contains(old.id) { try old.delete(db) }
        let oldRows = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        // Long live recordings generally append/change a handful of utterances;
        // do not rewrite the entire meeting or its unchanged historical versions.
        for utterance in utterances where oldRows[utterance.id] != utterance { try utterance.upsert(db) }
    }

    static func uuid(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else { throw CocoaError(.fileReadCorruptFile) }
        return id
    }
}

struct NoteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notes"
    var id: String
    // Keep Foundation's epoch to preserve Date's exact subsecond representation.
    var createdAt: Double
    var title: String
    var text: String
    var translation: String?
    var sourceLanguage: String
    var targetLanguage: String?
    var duration: Double
    var model: String
    var sourceFileName: String?
    var transcriptionComplete: Bool?
    var translationNeedsUpdate: Bool?
    var translationIncomplete: Bool?
    var captureRevision: String?
    var captureClosed: Bool?
    var audioID: String?
    var audioFilename: String?
    var audioIsMicrophone: Bool?
    var hasUtterances: Bool
    var hasVersions: Bool

    init(_ note: VoiceNote) {
        id = note.id.uuidString; createdAt = note.createdAt.timeIntervalSinceReferenceDate
        title = note.title; text = note.text; translation = note.translation
        sourceLanguage = note.sourceLanguage; targetLanguage = note.targetLanguage
        duration = note.duration; model = note.model; sourceFileName = note.sourceFileName
        transcriptionComplete = note.transcriptionComplete; translationNeedsUpdate = note.translationNeedsUpdate
        translationIncomplete = note.translationIncomplete; captureClosed = note.captureClosed
        captureRevision = note.captureRevision.map(String.init)
        audioID = note.audio?.recordingID.uuidString; audioFilename = note.audio?.filename
        audioIsMicrophone = note.audio?.isMicrophoneRecording
        hasUtterances = note.utterances != nil; hasVersions = note.transcriptVersions != nil
    }

    func note() throws -> VoiceNote {
        var value = VoiceNote(id: try NoteDatabase.uuid(id), createdAt: Date(timeIntervalSinceReferenceDate: createdAt),
            text: text, translation: translation, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, duration: duration, model: model)
        value.sourceFileName = sourceFileName; value.transcriptionComplete = transcriptionComplete
        value.translationNeedsUpdate = translationNeedsUpdate; value.translationIncomplete = translationIncomplete
        value.captureRevision = captureRevision.flatMap(UInt64.init); value.captureClosed = captureClosed
        if let audioID, let audioFilename {
            value.audio = RecordedAudio(recordingID: try NoteDatabase.uuid(audioID), filename: audioFilename, isMicrophoneRecording: audioIsMicrophone)
        }
        return value
    }
}

struct VersionRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "transcriptVersions"
    var id: String
    var noteID: String
    var position: Int
    var savedAt: Double
    var text: String
    var translation: String?
    var sourceLanguage: String
    var targetLanguage: String?
    var hasUtterances: Bool
    init(_ version: TranscriptVersion, noteID: String, position: Int) {
        id = version.id.uuidString; self.noteID = noteID; self.position = position
        savedAt = version.savedAt.timeIntervalSinceReferenceDate
        text = version.text; translation = version.translation
        sourceLanguage = version.sourceLanguage; targetLanguage = version.targetLanguage
        hasUtterances = version.utterances != nil
    }
}

struct UtteranceRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "utterances"
    var id: String
    var noteID: String
    var versionID: String?
    var localID: String
    var position: Int
    var startSample: Int
    var endSample: Int
    var text: String
    var translation: String?
    var settled: Bool
    var translationFailed: Bool?
    init(_ utterance: RecordedUtterance, noteID: String, versionID: String?, position: Int) {
        // Globally unique, stable identity even though capture uses local counters.
        id = (versionID ?? noteID) + ":" + String(utterance.id)
        self.noteID = noteID; self.versionID = versionID; self.position = position
        localID = String(utterance.id); startSample = utterance.startSample; endSample = utterance.endSample
        text = utterance.text; translation = utterance.translation; settled = utterance.settled
        translationFailed = utterance.translationFailed
    }
    func utterance() throws -> RecordedUtterance {
        guard let localID = UInt64(localID) else { throw CocoaError(.fileReadCorruptFile) }
        var value = RecordedUtterance(id: localID, startSample: startSample, endSample: endSample, text: text, translation: translation, settled: settled)
        value.translationFailed = translationFailed
        return value
    }
}
