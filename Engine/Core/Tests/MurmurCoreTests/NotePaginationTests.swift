import XCTest
@testable import MurmurCore

final class NotePaginationTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func note(_ index: Int, date: Double = 100) -> VoiceNote {
        VoiceNote(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                  createdAt: Date(timeIntervalSince1970: date), text: "Note \(index)", sourceLanguage: "fi", duration: 10, model: "test")
    }

    func testPagesHaveStableTieBreakingAndNoDuplicatesAfterInsertAndDelete() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NoteRepository(directory: directory)
        for index in 1...123 { try await repository.save(note(index)) }
        let first = try await repository.page()
        XCTAssertEqual(first.items.count, 50)
        XCTAssertEqual(first.items.first?.id, note(123).id)
        XCTAssertEqual(first.items.last?.id, note(74).id)
        try await repository.save(note(200, date: 200))
        try await repository.delete(note(100).id) // deletion before the cursor must not shift the next page
        let second = try await repository.page(after: first.next)
        let third = try await repository.page(after: second.next)
        XCTAssertEqual(second.items.count, 50); XCTAssertEqual(third.items.count, 23)
        XCTAssertNil(third.next)
        let ids = (first.items + second.items + third.items).map(\.id)
        XCTAssertEqual(Set(ids).count, 123)
        XCTAssertEqual(ids, (1...123).reversed().map { note($0).id })
    }

    func testSearchFindsUnloadedFullTextAndTranslationsWithUnicodeAndLiteralWildcards() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NoteRepository(directory: directory)
        for index in 1...60 { try await repository.save(note(index)) }
        var old = note(1, date: 1)
        old.text = String(repeating: "long meeting ", count: 1000) + "ПРИВЕТ ЁЖ"
        old.translation = "HYVÄÄ 50%_done"
        try await repository.save(old)
        let first = try await repository.page()
        XCTAssertFalse(first.items.contains { $0.id == old.id })
        let russian = try await repository.page(query: "привет ёж")
        XCTAssertEqual(russian.items.map(\.id), [old.id])
        let finnish = try await repository.page(query: "hyvää")
        XCTAssertEqual(finnish.items.map(\.id), [old.id])
        let literal = try await repository.page(query: "%_")
        XCTAssertEqual(literal.items.map(\.id), [old.id])
        let lineBreak = try await repository.page(query: "\n")
        XCTAssertEqual(lineBreak.items.map(\.id), [old.id])
        let combinedText = try await repository.page(query: "ЁЖ\n\nHYVÄÄ")
        XCTAssertEqual(combinedText.items.map(\.id), [old.id])
        let injection = try await repository.page(query: "' OR 1=1 --")
        XCTAssertTrue(injection.items.isEmpty)
    }

    func testAllFieldsHistoryAudioAndDeletionRoundTrip() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        var value = note(1)
        value.sourceFileName = "Meeting.wav"; value.translation = "Перевод"
        value.targetLanguage = "ru"; value.transcriptionComplete = false; value.captureClosed = true
        value.captureRevision = UInt64.max; value.translationNeedsUpdate = true; value.translationIncomplete = true
        value.audio = RecordedAudio(recordingID: value.id, isMicrophoneRecording: nil)
        var utterance = RecordedUtterance(id: UInt64.max, startSample: 0, endSample: 16000, text: "Original", settled: true)
        utterance.translationFailed = true
        value.utterances = [utterance]
        value.transcriptVersions = [TranscriptVersion(note: value, savedAt: Date(timeIntervalSince1970: 42))]
        let repository = NoteRepository(directory: directory)
        try await repository.save(value)
        let reopened = NoteRepository(directory: directory)
        let restored = try await reopened.note(value.id)
        XCTAssertEqual(restored, value)
        try await reopened.delete(value.id)
        try await repository.saveProgress(value)
        let remaining = try await repository.all()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAudioReferenceCheckIncludesNotesOutsideLoadedPage() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NoteRepository(directory: directory)
        var old = note(1, date: 1); old.audio = RecordedAudio()
        for index in 2...60 { try await repository.save(note(index)) }
        try await repository.save(old)
        let first = try await repository.page()
        XCTAssertFalse(first.items.contains { $0.id == old.id })
        let referenced = try await repository.hasAudioReference(old.audio!.recordingID)
        XCTAssertTrue(referenced)
        try await repository.delete(old.id)
        let unreferenced = try await repository.hasAudioReference(old.audio!.recordingID)
        XCTAssertFalse(unreferenced)
    }

    func testSummaryIsBoundedWhileOpeningRetainsFullLongMeeting() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        var long = note(1)
        long.text = String(repeating: "Transcript line. ", count: 20_000)
        long.utterances = (1...240).map { .init(id: UInt64($0), startSample: $0 * 16000, endSample: ($0 + 1) * 16000, text: "Phrase \($0)") }
        long.transcriptVersions = [TranscriptVersion(note: long)]
        let repository = NoteRepository(directory: directory)
        try await repository.save(long)
        let page = try await repository.page()
        XCTAssertEqual(page.items.first?.preview.count, 300)
        let opened = try await repository.note(long.id)
        XCTAssertEqual(opened, long)
    }

    func testDatesRoundTripWithoutLosingPrecisionAndEmptyCollectionsStayEmpty() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NoteRepository(directory: directory)
        var value = note(1)
        value.createdAt = Date(timeIntervalSinceReferenceDate: Double(800_000_000).nextUp)
        value.utterances = []; value.transcriptVersions = []
        try await repository.save(value)
        let restored = try await repository.note(value.id)
        let summary = try await repository.page().items.first
        XCTAssertEqual(restored, value)
        XCTAssertEqual(summary?.createdAt, value.createdAt)
    }

    @MainActor func testListLoadsOnlyRequestedPagesAndSearchResetsCursor() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NoteRepository(directory: directory)
        for index in 1...123 { try await repository.save(note(index)) }
        let list = NoteList(repository: repository)
        await list.reload()
        XCTAssertEqual(list.items.count, 50)
        await list.loadMore()
        XCTAssertEqual(list.items.count, 100)
        await list.loadMore()
        XCTAssertEqual(list.items.count, 123); XCTAssertNil(list.next)
        await list.search("Note 123")
        XCTAssertEqual(list.items.map(\.id), [note(123).id]); XCTAssertNil(list.next)
        await list.search("")
        XCTAssertEqual(list.items.count, 50)
    }

    @MainActor func testLatePageCannotAppendToNewSearch() async throws {
        let late = SuspendedPage()
        let first = NoteSummary(note(1)), last = NoteSummary(note(2))
        let list = NoteList(pageSize: 1) { query, cursor, _ in
            if query == "new" { return NotePage(items: [last], next: nil) }
            if cursor != nil { return await late.wait() }
            return NotePage(items: [first], next: .init(first))
        }
        await list.reload()
        let loading = Task { await list.loadMore() }
        await late.waitUntilStarted()
        await list.search("new")
        await late.resume(NotePage(items: [first], next: .init(first)))
        await loading.value
        XCTAssertEqual(list.items.map(\.id), [last.id]); XCTAssertNil(list.next)
        XCTAssertFalse(list.isLoading); XCTAssertNil(list.error)
    }

    @MainActor func testFailedPageKeepsLoadedCardsAndRetriesTheSameCursor() async throws {
        let first = NoteSummary(note(1)), second = NoteSummary(note(2))
        let failure = FailOnce()
        let list = NoteList(pageSize: 1) { _, cursor, _ in
            if cursor == nil { return NotePage(items: [first], next: .init(first)) }
            try await failure.check()
            return NotePage(items: [second], next: nil)
        }
        await list.reload()
        await list.loadMore()
        XCTAssertEqual(list.items, [first]); XCTAssertNotNil(list.next)
        XCTAssertNotNil(list.error); XCTAssertFalse(list.isLoading)
        await list.retry()
        XCTAssertEqual(list.items, [first, second]); XCTAssertNil(list.next)
        XCTAssertNil(list.error); XCTAssertFalse(list.isLoading)
    }
}

private actor FailOnce {
    private var failed = false
    func check() throws {
        if !failed { failed = true; throw CocoaError(.fileReadUnknown) }
    }
}

private actor SuspendedPage {
    private var continuation: CheckedContinuation<NotePage, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async -> NotePage {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; started?.resume(); started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resume(_ page: NotePage) { continuation?.resume(returning: page); continuation = nil }
}
