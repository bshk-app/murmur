import Foundation

/// Live draft plus a batch final on the same utterance audio.
///
/// The live lane is whatever the caller injects (Nemotron streaming). The batch
/// lane sees the whole buffer at `finishText()` and is the pasted result.
final class TwoPassSession: UtteranceSession {
    private let liveStep: ([Float]) -> Void
    private let liveText: () -> String
    private let liveFinish: () -> Void
    private let batch: ([Float]) -> String

    private var buffer: [Float] = []
    private var liveReleased = false

    init(
        liveStep: @escaping ([Float]) -> Void,
        liveText: @escaping () -> String,
        liveFinish: @escaping () -> Void,
        batch: @escaping ([Float]) -> String
    ) {
        self.liveStep = liveStep
        self.liveText = liveText
        self.liveFinish = liveFinish
        self.batch = batch
    }

    /// Stop spending compute on the live draft. Further `step`s only append audio
    /// for the batch pass — used on hotkey release so a capture backlog cannot
    /// delay paste.
    func releaseLive() {
        liveReleased = true
    }

    func step(_ samples: [Float]) -> (confirmed: String, partial: String) {
        buffer.append(contentsOf: samples)
        if !liveReleased {
            liveStep(samples)
        }
        return currentText
    }

    var currentText: (confirmed: String, partial: String) { ("", liveText()) }

    func finishText() -> String {
        if !liveReleased {
            liveReleased = true
            liveFinish()
        }
        let final = batch(buffer)
        return final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : final
    }
}
