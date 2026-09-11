import Foundation
import Observation
import GRDB

public struct NoteSummary: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let title: String
    public let preview: String
    public let sourceLanguage: String
    public let targetLanguage: String?
    public let transcriptionComplete: Bool?

    public init(_ note: VoiceNote) {
        id = note.id; createdAt = note.createdAt; title = note.title
        preview = String((note.translation ?? note.text).prefix(300))
        sourceLanguage = note.sourceLanguage; targetLanguage = note.targetLanguage
        transcriptionComplete = note.transcriptionComplete
    }

    init(row: Row) throws {
        id = try NoteDatabase.uuid(row["id"])
        createdAt = Date(timeIntervalSinceReferenceDate: row["createdAt"])
        title = row["title"]; preview = row["preview"]
        sourceLanguage = row["sourceLanguage"]; targetLanguage = row["targetLanguage"]
        transcriptionComplete = row["transcriptionComplete"]
    }
}

public struct NotePage: Sendable {
    public struct Cursor: Hashable, Sendable {
        public let id: UUID
        public let createdAt: Double
        public init(_ note: NoteSummary) {
            id = note.id; createdAt = note.createdAt.timeIntervalSinceReferenceDate
        }
    }
    public let items: [NoteSummary]
    public let next: Cursor?
    public init(items: [NoteSummary], next: Cursor?) { self.items = items; self.next = next }
}

/// Owns pagination independently of recording/navigation. Obsolete requests can
/// never append results to a newer search, including when a view task is cancelled.
@MainActor @Observable public final class NoteList {
    public private(set) var items: [NoteSummary] = []
    public private(set) var next: NotePage.Cursor?
    public private(set) var query = ""
    public private(set) var isLoading = false
    public private(set) var error: String?
    public private(set) var hasLoaded = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var retryingPage = false
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let loadPage: @Sendable (String, NotePage.Cursor?, Int) async throws -> NotePage

    public init(pageSize: Int = 50, loadPage: @escaping @Sendable (String, NotePage.Cursor?, Int) async throws -> NotePage) {
        self.pageSize = pageSize; self.loadPage = loadPage
    }

    public convenience init(repository: NoteRepository, pageSize: Int = 50) {
        self.init(pageSize: pageSize) { query, cursor, limit in
            try await repository.page(after: cursor, query: query, limit: limit)
        }
    }

    public func search(_ text: String) async {
        guard text != query || !hasLoaded else { return }
        query = text
        await reload()
    }

    /// Refresh only as many cards as were already loaded, preserving scroll anchors.
    public func reload(preservingCount: Bool = false) async {
        let token = UUID(); generation = token
        let wanted = preservingCount ? max(pageSize, items.count) : pageSize
        let currentQuery = query
        isLoading = true; error = nil
        if !preservingCount { items = []; next = nil }
        defer { if generation == token { isLoading = false } }
        do {
            var loaded: [NoteSummary] = []
            var cursor: NotePage.Cursor?
            repeat {
                let page = try await loadPage(currentQuery, cursor, min(pageSize, wanted - loaded.count))
                try Task.checkCancellation()
                guard generation == token else { return }
                loaded += page.items; cursor = page.next
            } while loaded.count < wanted && cursor != nil
            items = loaded; next = cursor; hasLoaded = true
        } catch is CancellationError {
            if generation == token { hasLoaded = false }
        } catch {
            if generation == token { self.error = error.localizedDescription; retryingPage = false }
        }
    }

    public func loadMore() async {
        guard !isLoading, let cursor = next else { return }
        let token = generation
        isLoading = true; error = nil
        defer { if generation == token { isLoading = false } }
        do {
            let page = try await loadPage(query, cursor, pageSize)
            try Task.checkCancellation()
            guard generation == token else { return }
            let existing = Set(items.map(\.id))
            items += page.items.filter { !existing.contains($0.id) }
            next = page.next
        } catch is CancellationError { }
        catch { if generation == token { self.error = error.localizedDescription; retryingPage = true } }
    }

    public func retry() async {
        if retryingPage { await loadMore() }
        else { await reload(preservingCount: true) }
    }

    #if DEBUG
    /// Existing design fixtures remain independent of an installed app's data.
    public convenience init(preview notes: [VoiceNote]) {
        self.init { query, cursor, limit in
            let values = notes.filter { query.isEmpty || $0.shareText.localizedCaseInsensitiveContains(query) }
                .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
                .filter { note in
                    guard let cursor else { return true }
                    return note.createdAt.timeIntervalSinceReferenceDate < cursor.createdAt ||
                        (note.createdAt.timeIntervalSinceReferenceDate == cursor.createdAt && note.id.uuidString < cursor.id.uuidString)
                }
            let items = values.prefix(limit).map(NoteSummary.init)
            return NotePage(items: items, next: values.count > limit ? items.last.map(NotePage.Cursor.init) : nil)
        }
        items = notes.prefix(50).map(NoteSummary.init)
        next = notes.count > 50 ? items.last.map(NotePage.Cursor.init) : nil
        hasLoaded = true
    }
    #endif
}
