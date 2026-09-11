import Foundation
import MLX

public struct ParakeetStreamingConfiguration: Sendable {
    public var windowDuration: TimeInterval
    public var updateInterval: TimeInterval
    public var confirmationDelay: TimeInterval
    public var overlapDuration: TimeInterval
    public var minimumAudioDuration: TimeInterval

    public init(
        windowDuration: TimeInterval = 9.5,
        updateInterval: TimeInterval = 1,
        confirmationDelay: TimeInterval = 2,
        overlapDuration: TimeInterval = 2,
        minimumAudioDuration: TimeInterval = 1.5,
    ) {
        self.windowDuration = windowDuration
        self.updateInterval = updateInterval
        self.confirmationDelay = confirmationDelay
        self.overlapDuration = overlapDuration
        self.minimumAudioDuration = minimumAudioDuration
    }

    func validate() throws {
        let values = [windowDuration, updateInterval, confirmationDelay, overlapDuration, minimumAudioDuration]
        guard values.allSatisfy(\.isFinite) else {
            throw STTError.invalidInput("Parakeet streaming durations must be finite")
        }
        guard windowDuration > 0, updateInterval > 0 else {
            throw STTError.invalidInput("Parakeet windowDuration and updateInterval must be positive")
        }
        guard confirmationDelay >= 0, minimumAudioDuration >= 0 else {
            throw STTError.invalidInput("Parakeet confirmationDelay and minimumAudioDuration cannot be negative")
        }
        guard overlapDuration > 0, updateInterval + overlapDuration <= windowDuration else {
            throw STTError.invalidInput(
                "Parakeet updateInterval plus overlapDuration must not exceed windowDuration",
            )
        }
        guard confirmationDelay < windowDuration, minimumAudioDuration <= windowDuration else {
            throw STTError.invalidInput(
                "Parakeet confirmationDelay and minimumAudioDuration must be shorter than the window",
            )
        }
    }
}

public struct ParakeetStreamUpdate: Sendable {
    public let text: String
    public let confirmedText: String
    public let tokens: [ParakeetAlignedToken]
    public let confirmedTokenCount: Int
    public let audioDuration: TimeInterval
    public let isFinal: Bool

    public var segments: [[String: Any]] {
        ParakeetAlignment.sentencesToResult(ParakeetAlignment.tokensToSentences(tokens)).segments
    }
}

public extension ParakeetModel {
    func makeStreamSession(
        configuration: ParakeetStreamingConfiguration = .init(),
    )
        throws -> ParakeetStreamSession
    {
        try configuration.validate()
        let samplesPerSecond = Double(preprocessConfig.sampleRate)
        guard configuration.windowDuration <= Double(Int.max) / samplesPerSecond else {
            throw STTError.invalidInput("Parakeet streaming window is too large")
        }

        #if canImport(CoreML)
            if let coreMLEncoder {
                let hopSeconds = Double(preprocessConfig.hopLength) / Double(preprocessConfig.sampleRate)
                let maxWindowDuration = Double(coreMLEncoder.fixedFrames - 4) * hopSeconds
                guard configuration.windowDuration <= maxWindowDuration else {
                    throw STTError.invalidInput(
                        "Parakeet streaming window exceeds the CoreML encoder limit of \(maxWindowDuration) seconds",
                    )
                }
            }
        #endif

        return ParakeetStreamSession(model: self, configuration: configuration)
    }
}

/// A bounded rolling-window session for microphone-style Parakeet transcription.
/// Calls are synchronous and must be serialized away from the real-time audio callback.
public final class ParakeetStreamSession {
    private let model: ParakeetModel
    private let configuration: ParakeetStreamingConfiguration
    private let sampleRate: Int
    private let windowSampleCount: Int
    private let updateSampleCount: Int
    private let confirmedBoundaryTolerance: TimeInterval

    private var audioBuffer: [Float] = []
    private var totalSampleCount = 0
    private var nextDecodeSampleCount: Int
    private var confirmedTokens: [ParakeetAlignedToken] = []
    private var provisionalTokens: [ParakeetAlignedToken] = []
    private var finalUpdate: ParakeetStreamUpdate?

    var bufferedSampleCount: Int {
        audioBuffer.count
    }

    static func tokensAfterConfirmedBoundary(
        _ tokens: [ParakeetAlignedToken],
        lastConfirmedToken: ParakeetAlignedToken,
        tolerance: TimeInterval,
    )
        -> [ParakeetAlignedToken]
    {
        let timestampEpsilon = 1e-9
        let timestampTolerance = tolerance + timestampEpsilon
        return tokens.filter { token in
            guard token.end > lastConfirmedToken.start + timestampEpsilon else {
                return false
            }
            guard token.end > lastConfirmedToken.end - timestampTolerance else {
                return false
            }
            let overlap = min(token.end, lastConfirmedToken.end)
                - max(token.start, lastConfirmedToken.start)
            let shorterDuration = min(token.duration, lastConfirmedToken.duration)
            let duplicatesLastToken =
                shorterDuration > 0
                    && overlap + timestampEpsilon >= shorterDuration / 2
            return !duplicatesLastToken
        }
    }

    init(model: ParakeetModel, configuration: ParakeetStreamingConfiguration) {
        self.model = model
        self.configuration = configuration
        sampleRate = model.preprocessConfig.sampleRate
        let windowSampleCount = max(1, Int(configuration.windowDuration * Double(sampleRate)))
        let updateSampleCount = max(1, Int(configuration.updateInterval * Double(sampleRate)))
        let minimumSampleCount = max(1, Int(configuration.minimumAudioDuration * Double(sampleRate)))
        confirmedBoundaryTolerance =
            Double(model.encoderConfig.subsamplingFactor * model.preprocessConfig.hopLength)
                / (2 * Double(sampleRate))
        self.windowSampleCount = windowSampleCount
        self.updateSampleCount = updateSampleCount
        nextDecodeSampleCount = max(updateSampleCount, minimumSampleCount)
    }

    /// Appends mono 16 kHz PCM and returns a complete transcript snapshot when an update is due.
    public func step(_ samples: [Float]) -> ParakeetStreamUpdate? {
        guard finalUpdate == nil, !samples.isEmpty else {
            return nil
        }

        var latestUpdate: ParakeetStreamUpdate?
        var start = 0
        while start < samples.count {
            let countUntilDecode = max(1, nextDecodeSampleCount - totalSampleCount)
            let end = min(start + countUntilDecode, samples.count)
            audioBuffer.append(contentsOf: samples[start ..< end])
            totalSampleCount += end - start
            start = end

            if totalSampleCount >= nextDecodeSampleCount {
                latestUpdate = decodeCurrentWindow(isFinal: false)
                nextDecodeSampleCount += updateSampleCount
            }
        }
        return latestUpdate
    }

    /// Appends an MLX audio array. Multichannel input is mixed down to mono.
    public func step(_ audio: MLXArray) -> ParakeetStreamUpdate? {
        let mono = audio.ndim > 1 ? audio.mean(axis: -1) : audio
        return step(mono.asType(.float32).asArray(Float.self))
    }

    /// Flushes the remaining audio and confirms the final snapshot. Idempotent.
    public func finish() -> ParakeetStreamUpdate {
        if let finalUpdate {
            return finalUpdate
        }

        let update: ParakeetStreamUpdate = if audioBuffer.isEmpty {
            makeUpdate(isFinal: true)
        } else {
            decodeCurrentWindow(isFinal: true)
        }
        finalUpdate = update
        return update
    }

    private func decodeCurrentWindow(isFinal: Bool) -> ParakeetStreamUpdate {
        let windowSamples = audioBuffer.count > windowSampleCount
            ? Array(audioBuffer.suffix(windowSampleCount))
            : audioBuffer
        let windowStartSample = totalSampleCount - windowSamples.count
        var incomingTokens = model.flattenTokens(from: model.decodeChunk(MLXArray(windowSamples)))
        let windowOffset = Double(windowStartSample) / Double(sampleRate)
        for index in incomingTokens.indices {
            incomingTokens[index].start += windowOffset
        }

        if let lastConfirmedToken = confirmedTokens.last {
            incomingTokens = Self.tokensAfterConfirmedBoundary(
                incomingTokens,
                lastConfirmedToken: lastConfirmedToken,
                tolerance: confirmedBoundaryTolerance,
            )
        }

        let merged = model.mergeTokenSequences(
            existing: provisionalTokens,
            incoming: incomingTokens,
            overlapDuration: configuration.overlapDuration,
        )
        let confirmationCutoff = isFinal
            ? .infinity
            : Double(totalSampleCount) / Double(sampleRate) - configuration.confirmationDelay
        let splitIndex = merged.firstIndex { $0.end > confirmationCutoff } ?? merged.endIndex

        confirmedTokens.append(contentsOf: merged[..<splitIndex])
        provisionalTokens = Array(merged[splitIndex...])
        trimAudioBuffer()
        Memory.clearCache()

        return makeUpdate(isFinal: isFinal)
    }

    private func trimAudioBuffer() {
        guard audioBuffer.count > windowSampleCount else {
            return
        }
        audioBuffer = Array(audioBuffer.suffix(windowSampleCount))
    }

    private func makeUpdate(isFinal: Bool) -> ParakeetStreamUpdate {
        let tokens = confirmedTokens + provisionalTokens
        let result = ParakeetAlignment.sentencesToResult(ParakeetAlignment.tokensToSentences(tokens))
        let confirmedResult = ParakeetAlignment.sentencesToResult(
            ParakeetAlignment.tokensToSentences(confirmedTokens),
        )
        return ParakeetStreamUpdate(
            text: result.text,
            confirmedText: confirmedResult.text,
            tokens: tokens,
            confirmedTokenCount: confirmedTokens.count,
            audioDuration: Double(totalSampleCount) / Double(sampleRate),
            isFinal: isFinal,
        )
    }
}
