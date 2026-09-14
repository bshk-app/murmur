import AVFoundation
import Foundation
import Observation

/// Records a voice note on the wrist. The file is the whole product here:
/// recognition needs models far larger than this device holds, so the watch
/// stops at a finished m4a and the phone does the rest.
@MainActor @Observable final class WatchRecorder {
    private(set) var recording = false
    var error: String?
    /// A call or Siri ends the recording where it stands. What reached the disk is
    /// still a note worth keeping, so it is handed over rather than discarded.
    @ObservationIgnored var onInterrupted: ((URL) -> Void)?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var interruption: (any NSObjectProtocol)?
    @ObservationIgnored private var starting = false

    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    func start() async {
        // Permission and session activation both suspend, and the button still
        // reads "Record" until they return. Without this, a second tap would
        // start a recording that replaces the first and is never sent.
        guard !recording, !starting else { return }
        starting = true
        defer { starting = false }
        error = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            error = L10n.text("Allow microphone access in Settings to record a note.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try await session.activate()
            // Sixteen kilohertz mono is what the phone resamples to anyway, and at
            // this bitrate a minute crosses the Bluetooth link in a few seconds.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(WatchHandoff.recordingName(startedAt: Date()))
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000])
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            recording = true
            observeInterruption()
        } catch {
            self.error = error.localizedDescription
            releaseSession()
        }
    }

    func stop() -> URL? {
        guard let recorder else { return nil }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        recording = false
        releaseSession()
        return url
    }

    private func observeInterruption() {
        guard interruption == nil else { return }
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                             object: AVAudioSession.sharedInstance(), queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in
                guard let self, let url = self.stop() else { return }
                self.onInterrupted?(url)
            }
        }
    }

    /// Holding the session open after recording drains the battery and would read
    /// as a microphone that never switches off.
    private func releaseSession() {
        if let interruption {
            NotificationCenter.default.removeObserver(interruption)
            self.interruption = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
