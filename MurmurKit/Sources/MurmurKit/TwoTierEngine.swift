import Foundation
import MLX
import MLXAudioSTT

/// Murmur's dictation composition. Caps Metal memory and loads the live
/// (Nemotron) and/or final (Parakeet) models **lazily, per mode**:
/// `prepare(.fast)` never pulls Parakeet, `prepare(.accurate)` never loads
/// Nemotron. A session accumulates audio, so each dictation needs a clean one.
///
/// Hybrid is one live stream plus one batch final — not two streaming models
/// on the same serial queue. Voxtral is not loaded.
public final class TwoTierEngine {
    public static let defaultNemotronRepo = "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
    public static let defaultParakeetRepo = "mlx-community/parakeet-tdt-0.6b-v3"

    /// Nemotron live-chunk. 160 ms is a documented ladder rung (`[56,1]`) — 80 ms
    /// has no lookahead and a worse live WER; 320 ms only existed to cheapen a
    /// Voxtral hybrid that is gone.
    public static let defaultFastChunkMs = 160

    /// Batch-final window. 120 s bounds long-dictation attention cost while
    /// keeping enough context to avoid the tail loss measured with 30 s windows.
    public static let finalChunkDuration: Float = 120

    private let nemotronRepo: String
    private let parakeetRepo: String
    private var nemotron: NemotronASRModel?
    private var parakeet: ParakeetModel?
    private var vad: SpeechBoundaryDetector?

    public static var defaultMemoryLimitBytes: Int {
        Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.6)
    }

    public init(
        nemotronRepo: String = defaultNemotronRepo,
        parakeetRepo: String = defaultParakeetRepo,
        memoryLimitBytes: Int = TwoTierEngine.defaultMemoryLimitBytes
    ) {
        GPU.set(memoryLimit: memoryLimitBytes, relaxed: false)
        self.nemotronRepo = nemotronRepo
        self.parakeetRepo = parakeetRepo
    }

    public func prepare(_ mode: DictationMode) async throws {
        switch mode {
        case .fast:     _ = try await loadNemotron()
        case .accurate: _ = try await loadParakeet()
        case .hybrid:   _ = try await loadNemotron(); _ = try await loadParakeet()
        }
    }

    /// Captions need both models plus the boundary detector. Same weights as
    /// `.hybrid` — a caption session must never load a second copy.
    public func prepareCaptions() async throws {
        _ = try await loadNemotron()
        _ = try await loadParakeet()
        if vad == nil { vad = try await SpeechBoundaryDetector.load() }
    }

    public var captionsReady: Bool {
        nemotron != nil && parakeet != nil && vad != nil
    }

    public func isReady(_ mode: DictationMode) -> Bool {
        switch mode {
        case .fast:     return nemotron != nil
        case .accurate: return parakeet != nil
        case .hybrid:   return nemotron != nil && parakeet != nil
        }
    }

    var supportedLanguageCodes: [String] {
        guard let nemotron else { return ["auto"] }
        return Self.canonicalLanguageCodes(nemotron.promptDictionary)
    }

    /// One code per prompt id: the dictionary lists several spellings of the same
    /// language ("en", "en-US"), and the picker shows one of each.
    static func canonicalLanguageCodes(_ prompts: [String: Int]) -> [String] {
        let aliasesByPrompt = Dictionary(grouping: prompts, by: { $0.value })
        let codes = aliasesByPrompt.values.compactMap { aliases in
            aliases.min { isPreferredSpelling($0.key, $1.key) }?.key
        }
        return codes.sorted {
            if $0 == "auto" { return true }
            if $1 == "auto" { return false }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// "auto" first, then bare codes ("ru"), then region-qualified ones ("en-GB"),
    /// alphabetical within a rank — the spelling a menu should show.
    private static func isPreferredSpelling(_ lhs: String, _ rhs: String) -> Bool {
        func rank(_ code: String) -> Int {
            if code == "auto" { return 0 }
            if code.count == 2 { return 1 }
            if code.contains("-") { return 2 }
            return 3
        }
        let (lhsRank, rhsRank) = (rank(lhs), rank(rhs))
        return lhsRank == rhsRank ? lhs < rhs : lhsRank < rhsRank
    }

    private func loadNemotron() async throws -> NemotronASRModel {
        if let nemotron { return nemotron }
        let m = try await NemotronASRModel.fromPretrained(nemotronRepo)
        nemotron = m
        return m
    }

    private func loadParakeet() async throws -> ParakeetModel {
        if let parakeet { return parakeet }
        let m = try await ParakeetModel.fromPretrained(parakeetRepo)
        parakeet = m
        return m
    }

    func makeSession(for mode: DictationMode, language: String? = nil) -> UtteranceSession? {
        switch mode {
        case .hybrid:   return makeHybridSession(language: language)
        case .fast:     return makeFastSession(language: language)
        case .accurate: return makeAccurateSession()
        }
    }

    /// Live Nemotron draft; pasted text is a Parakeet batch of the whole utterance.
    func makeHybridSession(language: String? = nil,
                           fastChunkMs: Int = defaultFastChunkMs) -> TwoPassSession? {
        guard let nemotron, let parakeet else { return nil }
        let live = nemotron.makeStreamSession(language: language, chunkMs: fastChunkMs)
        return TwoPassSession(
            liveStep: { _ = live.step($0) },
            liveText: { live.text },
            liveFinish: { _ = live.finish() },
            batch: { Self.parakeetBatch(parakeet, $0) }
        )
    }

    func makeFastSession(language: String? = nil, chunkMs: Int = defaultFastChunkMs) -> UtteranceSession? {
        guard let nemotron else { return nil }
        return NemotronOnlySession(nemotron, language: language, chunkMs: chunkMs)
    }

    /// No live draft — the buffer is decoded once at release.
    func makeAccurateSession() -> TwoPassSession? {
        guard let parakeet else { return nil }
        return TwoPassSession(
            liveStep: { _ in },
            liveText: { "" },
            liveFinish: {},
            batch: { Self.parakeetBatch(parakeet, $0) }
        )
    }

    /// Captions: one continuous Nemotron epoch per phrase, corrected by a
    /// Parakeet batch of that phrase's audio, with Silero marking the seams.
    ///
    /// The detector's streaming state is per talk, so it is cleared here rather
    /// than carried into the next session from whatever the last one heard.
    ///
    /// The live stream is rebuilt on `begin` — a real pause is the only place an
    /// epoch restarts, and a fresh session is how Nemotron's cost is kept flat
    /// over an hour-long talk.
    func makeCaptionEngine(language: String? = nil,
                           fastChunkMs: Int = defaultFastChunkMs,
                           maxEpochSeconds: Double = CaptionEngine.defaultMaxEpochSeconds) -> CaptionEngine? {
        guard let nemotron, let parakeet, let vad else { return nil }
        vad.reset()
        var live: NemotronASRStreamSession?
        return CaptionEngine(
            live: CaptionEngine.LiveLane(
                begin: { live = nemotron.makeStreamSession(language: language, chunkMs: fastChunkMs) },
                step: { if let live { _ = live.step($0) } },
                text: { live?.text ?? "" },
                finish: { if let live { _ = live.finish() }; live = nil }
            ),
            isSpeech: { vad.isSpeech($0) },
            batch: { _, samples in Self.parakeetBatch(parakeet, samples) },
            maxEpochSeconds: maxEpochSeconds
        )
    }

    static func parakeetBatch(_ model: ParakeetModel, _ samples: [Float]) -> String {
        guard !samples.isEmpty else { return "" }
        let params = STTGenerateParameters(language: nil, chunkDuration: finalChunkDuration)
        return model.generate(audio: MLXArray(samples), generationParameters: params).text
    }
}
