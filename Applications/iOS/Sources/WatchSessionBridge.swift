import Foundation
import MurmurCore
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

    /// Reports a finished transcript back to the wrist that spoke it. Queued
    /// rather than pushed as state: it belongs to one recording, and a later one
    /// must not erase it before it arrives.
    func send(transcript: String, for recording: String) {
        guard let session, session.activationState == .activated else { return }
        session.transferUserInfo([WatchHandoff.transcript: String(transcript.prefix(WatchHandoff.transcriptLimit)),
                                  WatchHandoff.recordingName: recording])
    }

    /// Offered once a watch is involved, because until then nothing would notify.
    @MainActor func requestNotificationAuthorizationIfNeeded(hasRecordings: Bool) async {
        let center = UNUserNotificationCenter.current()
        let undecided = await center.notificationSettings().authorizationStatus == .notDetermined
        WatchDiagnostics.note("permission check",
                              "status=\(await WatchDiagnostics.notificationStatus()) watchApp=\(isWatchAppInstalled) "
                                  + "recordings=\(hasRecordings) \(WatchDiagnostics.state())")
        guard WatchImportPolicy.shouldAskAboutNotifications(watchAppInstalled: isWatchAppInstalled,
                                                            hasRecordings: hasRecordings,
                                                            foreground: UIApplication.shared.applicationState == .active,
                                                            undecided: undecided) else { return }
        WatchDiagnostics.note("asking for notification permission")
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        WatchDiagnostics.note("permission now", await WatchDiagnostics.notificationStatus())
    }

    @MainActor private func announce() {
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Recording from Apple Watch received")
        content.body = L10n.text("Transcription starts when you open Murmator.")
        content.sound = .default
        // One identifier on purpose: a burst of recordings replaces one banner
        // instead of stacking a column of them.
        WatchDiagnostics.note("posting arrival banner", WatchDiagnostics.state())
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watch-recording", content: content, trigger: nil))
    }

    /// Says the note is ready, and nothing more. The recording's own name is the
    /// body: keeping the transcript off the lock screen is the whole point of
    /// recognising it on the device. Silent while the app is in front, where the
    /// note simply appears.
    @MainActor func announceCompletion(recording: String) {
        WatchDiagnostics.note("transcript finished", WatchDiagnostics.state())
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Transcription saved")
        content.body = recording
        content.sound = .default
        // Its own identifier, so finishing never overwrites an arrival the person
        // has not read yet.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watch-transcript", content: content, trigger: nil))
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

    /// The watch sends this purely to wake us. Arriving at all is the whole point;
    /// the queued file follows on its own.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            WatchDiagnostics.note("woken by the watch", WatchDiagnostics.state())
            await self.onRecordingStaged?()
        }
    }

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
        } catch {
            WatchDiagnostics.note("staging failed", error.localizedDescription)
            return
        }
        Task { @MainActor in
            WatchDiagnostics.note("recording staged", destination.lastPathComponent + " " + WatchDiagnostics.state())
            if UIApplication.shared.applicationState != .active { self.announce() }
            await self.onRecordingStaged?()
        }
    }
}
