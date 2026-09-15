import Foundation
import Observation
import WatchConnectivity
import WatchKit

/// Carries finished recordings to the phone and mirrors what the phone can do with
/// them. A recording stays in the outbox until the system confirms the transfer, so
/// a lost connection, a relaunch or a flat battery never costs a note.
@MainActor @Observable final class WatchSync: NSObject, WCSessionDelegate {
    private(set) var languageName: String?
    private(set) var speechReady = true
    private(set) var pending = 0
    /// The phone's answer for the last recording sent from here.
    private(set) var transcript: String?
    /// Whether an answer has ever arrived. Before the first one there is room on
    /// the screen to say where the audio went.
    private(set) var hasEverReceived = false
    var error: String?

    static var outbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Outbox")
    }
    private static let transcriptKey = "lastWatchTranscript"
    private static let everReceivedKey = "watchTranscriptEverReceived"

    override init() {
        super.init()
        // A transcript can arrive while the app is not running. watchOS may end
        // that process before anyone looks, so the answer is kept on disk.
        transcript = UserDefaults.standard.string(forKey: Self.transcriptKey)
        hasEverReceived = UserDefaults.standard.bool(forKey: Self.everReceivedKey)
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Recording happens in the temporary folder, so only a file that reached the
    /// outbox is complete and a resend can never pick up a half-written one.
    func send(_ url: URL) {
        // The previous answer belongs to the previous recording.
        transcript = nil
        UserDefaults.standard.removeObject(forKey: Self.transcriptKey)
        do {
            try FileManager.default.createDirectory(at: Self.outbox, withIntermediateDirectories: true)
            let destination = Self.outbox.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: url, to: destination)
            transfer(destination)
        } catch { self.error = error.localizedDescription }
    }

#if DEBUG
    @ObservationIgnored private var capturing = false
    /// Stands in for the phone while a simulator screenshot is taken.
    func seedForCapture(languageName: String, speechReady: Bool = true, pending: Int = 0,
                        hasEverReceived: Bool = false, transcript: String? = nil) {
        capturing = true
        self.languageName = languageName
        self.speechReady = speechReady
        self.pending = pending
        self.hasEverReceived = hasEverReceived
        self.transcript = transcript
    }
#endif

    /// Anything left in the outbox was never confirmed: a transfer that failed, or
    /// a recording the app was killed before handing over.
    private func resend() {
#if DEBUG
        // Activation would otherwise reset a seeded transfer count to zero.
        if capturing { return }
#endif
        let outstanding = Set(WCSession.default.outstandingFileTransfers.map { $0.file.fileURL.standardizedFileURL })
        let waiting = (try? FileManager.default.contentsOfDirectory(at: Self.outbox, includingPropertiesForKeys: nil)) ?? []
        for url in waiting where !outstanding.contains(url.standardizedFileURL) { transfer(url) }
        pending = WCSession.default.outstandingFileTransfers.count
    }

    private func transfer(_ url: URL) {
        WCSession.default.transferFile(url, metadata: nil)
        pending = WCSession.default.outstandingFileTransfers.count
    }

    private func apply(_ context: [String: Any]) {
        if let name = context[WatchHandoff.languageName] as? String { languageName = name }
        if let ready = context[WatchHandoff.speechReady] as? Bool { speechReady = ready }
    }

    /// A tap on the wrist is the point of the answer: it arrives while the phone
    /// is still in a pocket.
    private func received(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        UserDefaults.standard.set(text, forKey: Self.transcriptKey)
        UserDefaults.standard.set(true, forKey: Self.everReceivedKey)
        transcript = text
        hasEverReceived = true
        // Only lands while the app is in front. Backgrounded delivery still keeps
        // the transcript; the tap is a bonus, not the delivery mechanism.
        WKInterfaceDevice.current().play(.success)
    }

    private func finished(_ url: URL, message: String?) {
        if let message { error = message } else { try? FileManager.default.removeItem(at: url) }
        pending = WCSession.default.outstandingFileTransfers.count
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.apply(context)
            self.resend()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.apply(context) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let text = userInfo[WatchHandoff.transcript] as? String
        Task { @MainActor in self.received(text) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        let message = error?.localizedDescription
        Task { @MainActor in self.finished(url, message: message) }
    }

    /// The phone coming back in range is the moment a failed transfer can succeed.
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.resend() }
    }
}
