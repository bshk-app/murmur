import Foundation

/// Suppresses duplicate snapshots at the pipeline/UI seam. CaptionTranscript
/// increments `revision` only when visible state changes; mic chunks do not, so
/// a silent stretch holds the revision still and never wakes the UI. A session
/// token also rejects a late callback from the mic that was just stopped.
struct CaptionSnapshotGate: Sendable {
    private var currentSession: UInt64 = 0
    private var lastRevision: UInt64 = 0

    mutating func beginSession() -> UInt64 {
        currentSession &+= 1
        lastRevision = 0
        return currentSession
    }

    mutating func shouldEmit(session: UInt64, revision: UInt64) -> Bool {
        guard session == currentSession, revision != lastRevision else { return false }
        lastRevision = revision
        return true
    }
}

/// The UI-agnostic captions pipeline: capture the mic, keep a live draft on
/// screen, and correct each phrase with the batch model as the talk goes on.
///
/// The difference from `DictationSession` is lifetime. A dictation is one
/// utterance ending in one paste; a caption session runs for a whole talk and
/// emits a rolling snapshot — confirmed phrases plus the current draft — with no
/// text injection at all.
///
/// `@unchecked Sendable`: `onSnapshot` fires on the mic capture queue and
/// `stop()` is meant to be called off the main thread; `start()`/`stop()` never
/// overlap (the caller's state machine guarantees it).
public final class CaptionSession: @unchecked Sendable {
    /// The phrase-length cap the engine applies unless a caller overrides it.
    /// Forwarded rather than redefined: the policy owner keeps the value, and the
    /// public surface only makes it visible to callers.
    public static let defaultMaxEpochSeconds = CaptionEngine.defaultMaxEpochSeconds

    /// Shared with every other pipeline built from the same `SpeechModels` — the
    /// app runs captions off the weights dictation already loaded.
    let engine: STTEngine
    private var mic = MicCapture()
    private var snapshotGate = CaptionSnapshotGate()

    /// Called on the mic capture queue for every chunk that changed the view.
    public var onSnapshot: ((CaptionSnapshot) -> Void)?

    public init(models: SpeechModels) {
        self.engine = models.engine
    }

    public var supportedLanguageCodes: [String] { engine.supportedLanguageCodes }

    public func isReady() -> Bool { engine.captionsReady() }

    /// Download (first run) + load + warm the models and the boundary detector.
    public func load() async throws { try await engine.prepareCaptions() }

    public func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void = { _ in }) {
        MicCapture.requestPermission(completion)
    }

    public func start(
        language: String? = "auto",
        microphoneUID: String? = nil
    ) throws {
        mic = MicCapture(inputDeviceUID: microphoneUID)
        engine.beginCaptions(language: language)
        let session = snapshotGate.beginSession()
        mic.onChunk = { [weak self] chunk in
            guard let self, let snapshot = self.engine.stepCaptions(chunk),
                  self.snapshotGate.shouldEmit(session: session, revision: snapshot.revision) else { return }
            self.onSnapshot?(snapshot)
        }
        try mic.start()
    }

    /// Stop capturing and finalize the phrase that was open, once.
    @discardableResult
    public func stop() -> CaptionSnapshot? {
        _ = mic.stop()
        let snapshot = engine.finishCaptions()
        mic = MicCapture()
        return snapshot
    }

    /// Offline captions over pre-loaded 16 kHz mono samples, fed in the same
    /// chunks as the mic path — for verifying phrase segmentation and correction
    /// latency on a fixed file, no mic involved.
    ///
    /// `onSnapshot` still fires per chunk, so a caller can watch the draft evolve.
    ///
    /// `maxEpochSeconds` is settable because the safety cap is the rarest path in
    /// production — natural speech pauses long before it — and a short cap is the
    /// only way to exercise its seam many times against the real models.
    public func captionOffline(
        _ samples: [Float],
        chunkSamples: Int = DictationSession.liveChunkSamples,
        language: String? = "auto",
        maxEpochSeconds: Double = CaptionSession.defaultMaxEpochSeconds
    ) -> CaptionOfflineResult {
        engine.beginCaptions(language: language, maxEpochSeconds: maxEpochSeconds)
        let wall0 = ProcessInfo.processInfo.systemUptime
        var compute = 0.0
        var i = 0
        while i < samples.count {
            let end = min(i + chunkSamples, samples.count)
            let t0 = ProcessInfo.processInfo.systemUptime
            let snapshot = engine.stepCaptions(Array(samples[i ..< end]))
            compute += ProcessInfo.processInfo.systemUptime - t0
            if let snapshot { onSnapshot?(snapshot) }
            i = end
        }
        let tf = ProcessInfo.processInfo.systemUptime
        let final = engine.finishCaptions()
        compute += ProcessInfo.processInfo.systemUptime - tf
        // The phrase closed by `finish` is a phrase like any other, so publish the
        // snapshot that carries it — otherwise the last one of every talk goes
        // unreported and any count taken from the callback is one short.
        if let final { onSnapshot?(final) }
        return CaptionOfflineResult(
            snapshot: final ?? CaptionSnapshot(revision: 0, confirmed: [], provisional: ""),
            audioSeconds: Double(samples.count) / 16_000.0,
            computeSeconds: compute,
            wallSeconds: ProcessInfo.processInfo.systemUptime - wall0
        )
    }
}

public struct CaptionOfflineResult: Sendable {
    public let snapshot: CaptionSnapshot
    public let audioSeconds: Double
    public let computeSeconds: Double
    public let wallSeconds: Double
    public var rtf: Double { audioSeconds > 0 ? computeSeconds / audioSeconds : 0 }

    /// Confirmed phrases as one paragraph — what the overlay reads out.
    public var text: String { snapshot.confirmed.map(\.text).joined(separator: " ") }
}
