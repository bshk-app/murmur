import Foundation

enum StoragePaths {
    static let group = "group.app.bshk.murmur.ios.shared"
    static var shared: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MurMur") }
    static var notes: URL { (shared ?? support).appendingPathComponent("NoteLibrary") }
    static var recordings: URL { notes.appendingPathComponent("Recordings") }
    static var models: URL { support.appendingPathComponent("Models") }
    static var translation: URL { TranslationPaths.models }
    static var draft: URL { notes.appendingPathComponent("draft.json") }
    static var latest: URL? { notes.appendingPathComponent("latest-transcript.txt") }
}
