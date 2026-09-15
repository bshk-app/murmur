import Foundation

/// Application-context keys the iPhone publishes to the watch. Foundation only:
/// the watch target cannot link the Engine packages.
enum WatchHandoff {
    static let languageName = "languageName"
    static let speechReady = "speechReady"
    /// Carried by the message whose only job is to rouse the phone.
    static let wake = "wake"
    static let transcript = "transcript"
    static let recordingName = "recordingName"
    /// The watch shows a glance, not a document, and the payload carrying it has
    /// a size limit of its own.
    static let transcriptLimit = 2_000
    /// Recording names are the note titles on the phone, so they stay human
    /// readable, sortable and free of path separators.
    static func recordingName(startedAt: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Apple Watch " + formatter.string(from: startedAt) + ".m4a"
    }
}
