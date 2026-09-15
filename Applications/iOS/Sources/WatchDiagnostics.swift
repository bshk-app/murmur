import Foundation
import OSLog
import UIKit
import UserNotifications

/// Timing for the watch handover. Written to the unified log and to stdout, so a
/// Mac can read it live over `devicectl device process launch --console` as well
/// as afterwards. One call per event and no state of its own: it must not change
/// what it measures.
enum WatchDiagnostics {
    private static let logger = Logger(subsystem: "app.bshk.murmur.ios", category: "watch")
    private static let launched = Date()

    static func note(_ event: String, _ detail: String = "") {
        let line = String(format: "[watch +%.1fs] %@ %@", Date().timeIntervalSince(launched), event, detail)
        logger.info("\(line, privacy: .public)")
        print(line)
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
}
