import XCTest
@testable import MurmurCore

final class NoteRepositoryTests: XCTestCase {
    func testOldJSONFilesDoNotPopulateTheDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = directory.appendingPathComponent("Entries")
        try FileManager.default.createDirectory(at: entries, withIntermediateDirectories: true)
        let old = VoiceNote(text: "Old note", sourceLanguage: "en", duration: 1, model: "test")
        try JSONEncoder().encode([old]).write(to: directory.appendingPathComponent("notes.json"))
        try JSONEncoder().encode(old).write(to: entries.appendingPathComponent(old.id.uuidString + ".json"))
        let repository = NoteRepository(directory: directory)
        let initial = try await repository.page()
        XCTAssertTrue(initial.items.isEmpty)
        let new = VoiceNote(text: "New note", sourceLanguage: "en", duration: 1, model: "test")
        try await repository.save(new)
        let stored = try await repository.all()
        XCTAssertEqual(stored, [new])
    }
    func test_persistence_update_delete_and_reopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NoteRepository(directory: directory)
        var note = VoiceNote(text: "First", sourceLanguage: "en", duration: 3, model: "hybrid")
        try await repository.save(note)
        note.text = "Corrected"; note.translation = "Исправлено"
        note.translationNeedsUpdate = true
        try await repository.save(note)
        let reopened = NoteRepository(directory: directory)
        let notes = try await reopened.all()
        XCTAssertEqual(notes, [note])
        XCTAssertEqual(notes[0].shareText, "Corrected\n\nИсправлено")
        try await reopened.delete(note.id)
        let empty = try await repository.all()
        XCTAssertTrue(empty.isEmpty)
    }
}
