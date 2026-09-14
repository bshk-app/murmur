import Foundation
import Observation
import WatchConnectivity

/// Carries finished recordings to the phone and mirrors what the phone can do with
/// them. A recording stays in the outbox until the system confirms the transfer, so
/// a lost connection, a relaunch or a flat battery never costs a note.
@MainActor @Observable final class WatchSync: NSObject, WCSessionDelegate {
    private(set) var languageName: String?
    private(set) var speechReady = true
    private(set) var pending = 0
    var error: String?

    static var outbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Outbox")
    }

    override init() {
        super.init()
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Recording happens in the temporary folder, so only a file that reached the
    /// outbox is complete and a resend can never pick up a half-written one.
    func send(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: Self.outbox, withIntermediateDirectories: true)
            let destination = Self.outbox.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: url, to: destination)
            transfer(destination)
        } catch { self.error = error.localizedDescription }
    }

    /// Anything left in the outbox was never confirmed: a transfer that failed, or
    /// a recording the app was killed before handing over.
    private func resend() {
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
