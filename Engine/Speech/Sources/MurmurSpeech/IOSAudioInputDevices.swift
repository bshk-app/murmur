import MurmurCore
#if os(iOS)
import AVFoundation

// iOS counterpart to the macOS CoreAudio device router.
enum AudioInputDevices {
    static func route(preferredUID: String?, on engine: AVAudioEngine, allowConcurrentPlayback: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        // There is no playback in this app. Allowing an HFP output while
        // requesting the built-in input can leave the route switching as the
        // engine starts. A recording-only session makes the input explicit.
        let options: AVAudioSession.CategoryOptions = preferredUID == "built-in" ? [] : [.allowBluetoothHFP]
        try session.setCategory(allowConcurrentPlayback ? .playAndRecord : .record, mode: .measurement,
                               options: allowConcurrentPlayback ? options.union([.mixWithOthers, .defaultToSpeaker]) : options)
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true)
        if preferredUID == "built-in",
           let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(microphone)
        } else {
            try session.setPreferredInput(nil)
        }
    }
}

#endif
