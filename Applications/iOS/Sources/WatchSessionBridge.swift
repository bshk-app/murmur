import Foundation
import UIKit
import UserNotifications
import WatchConnectivity

/// Receives recordings from the watch app and stages them for the audio import.
/// Nothing here decides when to transcribe. A recording arrives whenever the watch
/// finds the phone, which may be locked, busy or asleep, so the staged file is the
/// durable handover and the model drains it when it can.
final class WatchSessionBridge: NSObject, WCSessionDelegate {
    var onSessionReady: (@MainActor () -> Void)?
    var onRecordingStaged: (@MainActor () async -> Void)?

    /// Absent on iPad, which has no watch session. Every call then does nothing.
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    var isWatchAppInstalled: Bool { session?.isWatchAppInstalled ?? false }

    /// Named by the watch as "Apple Watch <date> <time>", so the order on disk is
    /// the order they were spoken.
    static func stagedRecordings() -> [URL] {
        let staged = (try? FileManager.default.contentsOfDirectory(at: StoragePaths.watchInbox, includingPropertiesForKeys: nil)) ?? []
        return staged.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The watch shows the language the phone would actually recognise, so it never
    /// invites a recording the phone has no models for.
    func publish(languageName: String, speechReady: Bool) {
        guard let session, session.activationState == .activated else { return }
        try? session.updateApplicationContext([WatchHandoff.languageName: languageName, WatchHandoff.speechReady: speechReady])
    }

    /// Asked for once the watch app exists, because until then nothing would notify.
    @MainActor func requestNotificationAuthorizationIfNeeded() async {
        guard isWatchAppInstalled, UIApplication.shared.applicationState == .active else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    @MainActor private func announce() {
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Recording from Apple Watch received")
        content.body = L10n.text("Transcription starts when you open Murmator.")
        content.sound = .default
        // One identifier on purpose: a burst of recordings replaces one banner
        // instead of stacking a column of them.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watch-recording", content: content, trigger: nil))
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.onSessionReady?() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.onSessionReady?() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Pairing a different watch deactivates the session. Without reactivating,
    /// recordings from the new watch would never arrive.
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The system deletes file.fileURL as soon as this returns, so the move
        // cannot wait for the main actor or for the import to accept the recording.
        let destination = StoragePaths.watchInbox.appendingPathComponent(file.fileURL.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: StoragePaths.watchInbox, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
            // Delivery to a locked phone is the normal case, and the drain that
            // reads this file runs long after the screen locks again.
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: destination.path)
        } catch { return }
        Task { @MainActor in
            if UIApplication.shared.applicationState != .active { self.announce() }
            await self.onRecordingStaged?()
        }
    }
}
