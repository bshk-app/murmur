import MurmurCore
#if os(iOS)
import AVFoundation

// iOS counterpart to the macOS CoreAudio device router.
enum AudioInputDevices {
    static func route(preferredUID: String?, on engine: AVAudioEngine, allowConcurrentPlayback: Bool = false,
                      voiceProcessing: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        // There is no playback in this app. Allowing an HFP output while
        // requesting the built-in input can leave the route switching as the
        // engine starts. A recording-only session makes the input explicit.
        // Voice processing is a full-duplex unit, so it needs playAndRecord;
        // measurement mode would switch the processing it asks for back off.
        var options: AVAudioSession.CategoryOptions = preferredUID == "built-in" ? [] : [.allowBluetoothHFP]
        if allowConcurrentPlayback { options.formUnion([.mixWithOthers, .defaultToSpeaker]) }
        if voiceProcessing { options.insert(.defaultToSpeaker) }
        try session.setCategory(allowConcurrentPlayback || voiceProcessing ? .playAndRecord : .record,
                                mode: voiceProcessing ? .voiceChat : .measurement, options: options)
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true)
        if preferredUID == "built-in",
           let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(microphone)
        } else {
            try session.setPreferredInput(nil)
        }
        if voiceProcessing {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            // One unit serves input and output; give the output side a graph so the engine can start.
            _ = engine.mainMixerNode
        }
    }
}

#endif
