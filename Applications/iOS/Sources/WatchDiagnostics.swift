import Foundation
import OSLog
import UIKit
import UserNotifications

/// Timing for the watch handover, appended to a file inside the app container.
/// A file rather than a console stream on purpose: the interesting events happen
/// while the phone is locked and the app is being woken and suspended, which is
/// exactly when an attached console drops. The file survives all of that and can
/// be pulled afterwards with `devicectl device copy from`.
enum WatchDiagnostics {
    private static let logger = Logger(subsystem: "app.bshk.murmur.ios", category: "watch")
    private static let lock = NSLock()
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static var file: URL { StoragePaths.support.appendingPathComponent("watch-diagnostics.log") }

    static func note(_ event: String, _ detail: String = "") {
        let line = "\(clock.string(from: Date())) \(event) \(detail)"
        logger.info("\(line, privacy: .public)")
        append(line)
    }

    /// The two numbers that decide whether background work can finish at all:
    /// how long iOS is still willing to run us, and whether files are readable.
    @MainActor static func state() -> String {
        let application = UIApplication.shared
        let phase: String
        switch application.applicationState {
        case .active: phase = "active"
        case .inactive: phase = "inactive"
        default: phase = "background"
        }
        let remaining = application.backgroundTimeRemaining
        let budget = remaining > 1_000_000 ? "budget=unbounded" : String(format: "budget=%.0fs", remaining)
        return "app=\(phase) \(budget) unlocked=\(application.isProtectedDataAvailable)"
    }

    @MainActor static func notificationStatus() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    /// Callers arrive from the Watch Connectivity queue as well as the main actor,
    /// so the appends are serialised rather than interleaved mid-line.
    private static func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return
        }
        try? manager.createDirectory(at: StoragePaths.support, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        // Written while the phone is locked, so it must not be sealed until unlock.
        try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                   ofItemAtPath: file.path)
    }
}
