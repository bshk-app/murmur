import AVFoundation
import Foundation
import Observation

/// Records a voice note on the wrist. The file is the whole product here:
/// recognition needs models far larger than this device holds, so the watch
/// stops at a finished m4a and the phone does the rest.
@MainActor @Observable final class WatchRecorder {
    private(set) var recording = false
    /// How long the last recording ran. Shown while it travels, so the length of
    /// what was sent is not a mystery.
    private(set) var lastDuration: TimeInterval = 0
    /// Only a refused microphone blocks the button. A session that failed to
    /// activate is worth showing and worth retrying, so it must not latch.
    private(set) var permissionDenied = false
    var error: String?
    /// A call or Siri ends the recording where it stands. What reached the disk is
    /// still a note worth keeping, so it is handed over rather than discarded.
    @ObservationIgnored var onInterrupted: ((URL) -> Void)?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var interruption: (any NSObjectProtocol)?
    @ObservationIgnored private var starting = false

    var elapsed: TimeInterval {
#if DEBUG
        if let capturedElapsed { return capturedElapsed }
#endif
        return recorder?.currentTime ?? 0
    }

#if DEBUG
    @ObservationIgnored private var capturedElapsed: TimeInterval?
    /// Stands in for the microphone while a simulator screenshot is taken.
    func seedForCapture(recording: Bool, elapsed: TimeInterval, denied: Bool = false) {
        capturedElapsed = recording ? elapsed : nil
        lastDuration = elapsed
        self.recording = recording
        permissionDenied = denied
        error = denied ? L10n.text("Allow microphone access in Settings to record a note.") : nil
    }
#endif

    func start() async {
        // Permission and session activation both suspend, and the button still
        // reads "Record" until they return. Without this, a second tap would
        // start a recording that replaces the first and is never sent.
        guard !recording, !starting else { return }
        starting = true
        defer { starting = false }
        error = nil
        let granted = await AVAudioApplication.requestRecordPermission()
        permissionDenied = !granted
        guard granted else {
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
        lastDuration = recorder.currentTime
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
