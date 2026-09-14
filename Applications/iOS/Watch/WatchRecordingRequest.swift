import AppIntents
import Foundation

extension Notification.Name {
    static let murmatorWatchRecordRequested = Notification.Name("murmator.watch.record.requested")
}

/// A request to record raised from the watch face or the Action Button. The flag
/// survives the launch the intent triggers, and the notification covers the case
/// where the app was already in front and will not launch again.
enum WatchRecordingRequest {
    private static let key = "pendingWatchRecording"
    static func raise() {
        UserDefaults.standard.set(true, forKey: key)
        NotificationCenter.default.post(name: .murmatorWatchRecordRequested, object: nil)
    }
    static func consume() -> Bool {
        guard UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.removeObject(forKey: key)
        return true
    }
}

/// The single way in for both the complication and the Action Button, so the
/// wrist never has to find the app before speaking.
struct StartWatchRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Record a Murmator note"
    static var description = IntentDescription("Start a recording on Apple Watch and send it to iPhone.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        WatchRecordingRequest.raise()
        return .result()
    }
}
