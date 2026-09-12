@preconcurrency import CoreML
import Foundation

/// Manager for NVIDIA Canary-1B-v2 transcription (attention encoder-decoder).
///
/// Pipeline: waveform → [Preprocessor fp32/CPU] mel → [Encoder int4/CPU+GPU] →
/// transpose to [1, T, D] → greedy autoregressive loop ([Decoder] → last hidden
/// → [Projection] → argmax until EOS) → SentencePiece detokenize.
///
/// Adapted from the Murmur standalone probe; see NOTICE.md in this directory.
/// The decoder carries no KV cache. Only one <=15 s window is accepted.
///
/// - Note: Beta — this is a beta model conversion; API, model artifacts, and accuracy may change.
actor CanaryQualificationDecoder {

    private let models: CanaryQualificationModels
    init(models: CanaryQualificationModels) { self.models = models }

    // Synchronous actor-isolated execution keeps windows serialized even when callers overlap.
    func process(audio: [Float], source: String, target: String?) throws -> CanaryResult {
        try CanaryRuntime.validateAudio(audio)
        try Task.checkCancellation()
        let (embeddings, encoderMask) = try autoreleasepool {
            let (mel, length) = try runPreprocessor(audio: audio)
            try Task.checkCancellation()
            let (encoder, encoderLength) = try runEncoder(mel: mel, melLength: length)
            try Task.checkCancellation()
            return try makeDecoderContext(encoder: encoder, encoderLength: encoderLength)
        }
        let sourceTokens = try greedyDecode(embeddings: embeddings, encoderMask: encoderMask,
                                            prompt: models.tokenizer.prompt(source: source, target: source))
        var translation: String?
        if let target {
            translation = detokenize(try greedyDecode(embeddings: embeddings, encoderMask: encoderMask,
                                                       prompt: models.tokenizer.prompt(source: source, target: target)))
        }
        try Task.checkCancellation()
        return CanaryResult(sourceText: detokenize(sourceTokens), translatedText: translation)
    }

    // MARK: - Pipeline

    /// waveform → mel [1, 128, 1501]. Audio is padded to the fixed 15 s window.
    private func runPreprocessor(audio: [Float]) throws -> (MLMultiArray, MLMultiArray) {
        let maxN = CanaryQualificationConfig.maxSamples
        let validN = min(audio.count, maxN)

        let signal = try MLMultiArray(shape: [1, maxN as NSNumber], dataType: .float32)
        let sptr = signal.dataPointer.assumingMemoryBound(to: Float32.self)
        memset(sptr, 0, maxN * MemoryLayout<Float32>.size)
        audio.prefix(validN).withUnsafeBufferPointer { src in
            sptr.update(from: src.baseAddress!, count: validN)
        }

        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: validN)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: signal),
            "audio_length": MLFeatureValue(multiArray: length),
        ])
        let out = try models.preprocessor.prediction(from: input)
        guard let mel = out.featureValue(for: "processed")?.multiArrayValue,
            let melLen = out.featureValue(for: "processed_length")?.multiArrayValue
        else {
            throw CanaryQualificationError.processingFailed("Canary preprocessor produced no `processed`")
        }
        return (mel, melLen)
    }

    /// mel → encoder [1, 1024, 188].
    private func runEncoder(mel: MLMultiArray, melLength: MLMultiArray) throws -> (MLMultiArray, Int) {
        let featLen = try MLMultiArray(shape: [1], dataType: .int32)
        featLen[0] = NSNumber(value: melLength[0].intValue)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "features": MLFeatureValue(multiArray: mel),
            "features_length": MLFeatureValue(multiArray: featLen),
        ])
        let out = try models.encoder.prediction(from: input)
        guard let enc = out.featureValue(for: "encoder")?.multiArrayValue else {
            throw CanaryQualificationError.processingFailed("Canary encoder produced no `encoder`")
        }
        let encLen = out.featureValue(for: "encoder_length")?.multiArrayValue?[0].intValue ?? CanaryQualificationConfig.encoderFrames
        return (enc, encLen)
    }

    /// encoder [1, D, T] → encoder_embeddings [1, T, D] + encoder_mask [1, T].
    ///
    /// CoreML pads the encoder's last dim to a 64-element boundary (T=188 →
    /// stride 192), so the transpose must use the array's real strides, not a
    /// dense linear read.
    private func makeDecoderContext(encoder: MLMultiArray, encoderLength: Int) throws -> (MLMultiArray, MLMultiArray) {
        let d = CanaryQualificationConfig.encoderHidden
        let t = CanaryQualificationConfig.encoderFrames
        let emb = try MLMultiArray(shape: [1, t as NSNumber, d as NSNumber], dataType: .float32)
        let eptr = emb.dataPointer.assumingMemoryBound(to: Float32.self)
        let strides = encoder.strides.map { $0.intValue }
        let sD = strides[1]
        let sT = strides[2]
        let read = floatReader(encoder)
        for ti in 0..<t {
            let dst = ti * d
            let tBase = ti * sT
            for di in 0..<d {
                eptr[dst + di] = read(di * sD + tBase)
            }
        }

        let mask = try MLMultiArray(shape: [1, t as NSNumber], dataType: .float32)
        let mptr = mask.dataPointer.assumingMemoryBound(to: Float32.self)
        let valid = min(max(encoderLength, 1), t)
        for i in 0..<t { mptr[i] = i < valid ? 1.0 : 0.0 }
        return (emb, mask)
    }

    /// Greedy autoregressive decode: returns generated token ids (prompt stripped).
    private func greedyDecode(embeddings: MLMultiArray, encoderMask: MLMultiArray, prompt: [Int32]) throws -> [Int] {
        // Use the decoder's actual sequence length (the exported `[1, S]` shape),
        // so a shorter decoder export (e.g. S=128) is picked up automatically.
        let s =
            models.decoder.modelDescription.inputDescriptionsByName["input_ids"]?
            .multiArrayConstraint?.shape.last?.intValue ?? CanaryQualificationConfig.maxDecoderSteps

        guard s > prompt.count, s <= CanaryQualificationConfig.maxDecoderSteps else { throw CanaryRuntime.Failure.decoderLimit }
        let inputIds = try MLMultiArray(shape: [1, s as NSNumber], dataType: .int32)
        let decoderMask = try MLMultiArray(shape: [1, s as NSNumber], dataType: .float32)
        let idptr = inputIds.dataPointer.assumingMemoryBound(to: Int32.self)
        let mkptr = decoderMask.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<s {
            idptr[i] = 0
            mkptr[i] = 0
        }
        let promptLen = min(prompt.count, s)
        for i in 0..<promptLen {
            idptr[i] = prompt[i]
            mkptr[i] = 1
        }
        var pos = promptLen

        let hidden = try MLMultiArray(shape: [1, CanaryQualificationConfig.encoderHidden as NSNumber], dataType: .float32)
        let hptr = hidden.dataPointer.assumingMemoryBound(to: Float32.self)
        let d = CanaryQualificationConfig.encoderHidden

        var generated: [Int] = []
        while pos < s {
            try Task.checkCancellation()
            // Bound temporary Objective-C prediction objects to a single token.
            let next: Int = try autoreleasepool {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: inputIds),
                "decoder_mask": MLFeatureValue(multiArray: decoderMask),
                "encoder_embeddings": MLFeatureValue(multiArray: embeddings),
                "encoder_mask": MLFeatureValue(multiArray: encoderMask),
            ])
            let out = try models.decoder.prediction(from: input)
            guard let dec = out.featureValue(for: "decoder")?.multiArrayValue else {
                throw CanaryQualificationError.processingFailed("Canary decoder produced no `decoder`")
            }

            // hidden state at the last valid position (decoder output may be stride-padded)
            let decStrides = dec.strides.map { $0.intValue }
            let rowBase = (pos - 1) * decStrides[1]
            let elemStride = decStrides[2]
            let readDec = floatReader(dec)
            for h in 0..<d { hptr[h] = readDec(rowBase + h * elemStride) }

            let projInput = try MLDictionaryFeatureProvider(dictionary: [
                "hidden": MLFeatureValue(multiArray: hidden)
            ])
            let projOut = try models.projection.prediction(from: projInput)
            guard let logits = projOut.featureValue(for: "logits")?.multiArrayValue else {
                throw CanaryQualificationError.processingFailed("Canary projection produced no `logits`")
            }

            return argmax(logits)
            }
            if next == CanaryQualificationConfig.eosId { return generated }

            generated.append(next)
            idptr[pos] = Int32(next)
            mkptr[pos] = 1
            pos += 1
        }
        throw CanaryRuntime.Failure.decoderLimit
    }

    private func detokenize(_ tokens: [Int]) -> String {
        models.tokenizer.decode(ids: tokens)
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - MLMultiArray helpers

    /// Returns a dtype-aware element reader for `arr` indexed by flat offset.
    /// The closure captures a pointer derived from `arr.dataPointer`; it is only
    /// valid while `arr` is alive (which it is for the duration of each use here).
    private func floatReader(_ arr: MLMultiArray) -> (Int) -> Float {
        switch arr.dataType {
        case .float32:
            let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
            return { p[$0] }
        case .float16:
            let p = arr.dataPointer.assumingMemoryBound(to: UInt16.self)
            return { canaryQualificationFloat16BitsToFloat(p[$0]) }
        default:
            return { arr[$0].floatValue }
        }
    }

    private func argmax(_ logits: MLMultiArray) -> Int {
        let n = logits.count
        var best = 0
        var bestVal = -Float.greatestFiniteMagnitude
        switch logits.dataType {
        case .float32:
            let p = logits.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<n where p[i] > bestVal {
                bestVal = p[i]
                best = i
            }
        case .float16:
            let p = logits.dataPointer.assumingMemoryBound(to: UInt16.self)
            for i in 0..<n {
                let v = canaryQualificationFloat16BitsToFloat(p[i])
                if v > bestVal {
                    bestVal = v
                    best = i
                }
            }
        default:
            for i in 0..<n {
                let v = logits[i].floatValue
                if v > bestVal {
                    bestVal = v
                    best = i
                }
            }
        }
        return best
    }
}

/// Decode an IEEE-754 half-precision bit pattern to Float (avoids a hard Float16 dependency).
@inline(__always)
func canaryQualificationFloat16BitsToFloat(_ h: UInt16) -> Float {
    let sign = UInt32(h & 0x8000) << 16
    let exp = UInt32(h & 0x7C00) >> 10
    let mant = UInt32(h & 0x03FF)
    if exp == 0 {
        if mant == 0 { return Float(bitPattern: sign) }
        // subnormal
        var e: UInt32 = 127 - 15 + 1
        var m = mant
        while (m & 0x0400) == 0 {
            m <<= 1
            e -= 1
        }
        m &= 0x03FF
        return Float(bitPattern: sign | (e << 23) | (m << 13))
    }
    if exp == 0x1F {
        return Float(bitPattern: sign | 0x7F80_0000 | (mant << 13))
    }
    let e = exp + 112
    return Float(bitPattern: sign | (e << 23) | (mant << 13))
}
