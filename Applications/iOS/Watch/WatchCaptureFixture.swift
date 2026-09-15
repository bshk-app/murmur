#if DEBUG
import Foundation

/// Seeds the states the phone would otherwise drive, so the design can be looked
/// at in a simulator that has no Watch Connectivity and no microphone. Compiled
/// out of Release: a shipped build has no argument that reaches any of this.
enum WatchCaptureFixture {
    @MainActor static func apply(recorder: WatchRecorder, sync: WatchSync) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--capture-state"), flag + 1 < arguments.count else { return }
        let language = "Русский"
        switch arguments[flag + 1] {
        case "ready":
            sync.seedForCapture(languageName: language, hasEverReceived: true)
        case "first-run":
            sync.seedForCapture(languageName: language)
        case "recording":
            sync.seedForCapture(languageName: language, hasEverReceived: true)
            recorder.seedForCapture(recording: true, elapsed: 42)
        case "sending":
            sync.seedForCapture(languageName: language, pending: 1, hasEverReceived: true)
            recorder.seedForCapture(recording: false, elapsed: 42)
        case "transcript":
            sync.seedForCapture(languageName: language, hasEverReceived: true,
                                transcript: "Ask Kolya to send the contract before Thursday.\n"
                                    + "If the price holds, we sign this week and start the pilot in October.")
        case "warning":
            sync.seedForCapture(languageName: language, speechReady: false, hasEverReceived: true)
        case "denied":
            sync.seedForCapture(languageName: language, hasEverReceived: true)
            recorder.seedForCapture(recording: false, elapsed: 0, denied: true)
        default:
            break
        }
    }
}
#endif
