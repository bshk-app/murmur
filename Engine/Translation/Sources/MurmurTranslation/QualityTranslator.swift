import MurmurCore
import Foundation
import MurmurMT

/// The engine used for text that gets pasted, as opposed to text that is only
/// shown while the user is still speaking.
///
/// Two engines exist because one cannot do both jobs. Measured on FLORES+
/// devtest ru->en, 1012 rows, beam 1, one thread, M1 Max:
///
///     bergamot student  56.79 chrF++   29.55 BLEU    12 ms   22.5 MB
///     opus-mt tc-big    60.40 chrF++   35.50 BLEU   378 ms  252.8 MB
///
/// The +3.61 chrF++ is worth having once, on the text the user keeps. It is
/// unaffordable on a live draft that retranslates several times a second, so
/// `Translator` keeps that job and this type never touches it.
///
/// Not `Sendable`, for the same reason as `Translator`: one instance owns one
/// loaded model and one non-reentrant C++ engine.
public final class QualityTranslator: TextTranslating {
    public enum Failure: Error, CustomStringConvertible {
        case modelUnavailable(pair: LanguagePair, path: String)
        case engine(String)

        public var description: String {
            switch self {
            case let .modelUnavailable(pair, path):
                return "no quality translation model for \(pair) at \(path)"
            case let .engine(message):
                return "quality translation engine: \(message)"
            }
        }
    }

    private let handle: OpaquePointer
    public let pair: LanguagePair
    private let decoding: TranslationDecodingProfile
    private let targetTag: String?

    /// Loads the converted CTranslate2 model for `pair` from `modelsRoot`.
    ///
    /// Unlike `Translator`, this is expected to fail routinely: the quality
    /// model is downloaded on demand and most pairs will not have one. Strict
    /// quality callers surface the failure; only the explicit legacy best-effort
    /// API may fall back to the preview engine.
    public init(pair: LanguagePair, modelsRoot: URL, modelDirectory: URL? = nil,
                decoding: TranslationDecodingProfile = .baseline,
                targetTag: String? = nil) throws {
        try decoding.validate()
        let directory = modelDirectory ?? modelsRoot
            .appendingPathComponent(pair.qualityModelDirectoryName)
        // model.bin alone is not enough: the SentencePiece models must be the
        // ones these weights were trained against, and a mismatch produces
        // fluent text unrelated to the input rather than an error.
        let required = ["model.bin", "config.json", "source.spm", "target.spm"]
        for file in required {
            let path = directory.appendingPathComponent(file).path
            guard FileManager.default.fileExists(atPath: path) else {
                throw Failure.modelUnavailable(pair: pair, path: directory.path)
            }
        }
        var error: UnsafeMutablePointer<CChar>?
        guard let opened = murmur_ct2_open_with_options(directory.path, decoding.computeType == .int8 ? 0 : 1, &error) else {
            defer { if let error { murmur_ct2_string_free(error) } }
            throw Failure.engine(
                error.map { String(cString: $0) } ?? "could not open model")
        }
        self.handle = opened
        self.pair = pair
        self.decoding = decoding
        self.targetTag = targetTag
    }

    deinit { murmur_ct2_close(handle) }

    /// Translates a whole committed dictation, which may be several sentences
    /// over several lines. The shim splits it: opus-mt is a sentence-level
    /// model and handing it a paragraph silently returns a fraction of it.
    public func translate(_ text: String) throws -> String {
        try translate(text, decoding: decoding, targetTag: targetTag)
    }

    /// Reuses loaded weights while selecting decoding and target independently
    /// for this call. Compute precision belongs to the loaded engine.
    public func translate(_ text: String, decoding: TranslationDecodingProfile,
                          targetTag: String?) throws -> String {
        try decoding.validate()
        guard decoding.computeType == self.decoding.computeType else {
            throw Failure.engine("compute type cannot change on a loaded model")
        }
        var error: UnsafeMutablePointer<CChar>?
        var options = MurmurCT2Options(beam_size: Int32(decoding.beamSize),
            max_source_pieces: Int32(decoding.maxSourcePieces),
            max_decoding_length: Int32(decoding.maxDecodingLength),
            length_penalty: decoding.lengthPenalty)
        let output: UnsafeMutablePointer<CChar>?
        if let targetTag {
            output = targetTag.withCString {
                murmur_ct2_translate_with_options(handle, text, &options, $0, &error)
            }
        } else {
            output = murmur_ct2_translate_with_options(handle, text, &options, nil, &error)
        }
        guard let out = output else {
            defer { if let error { murmur_ct2_string_free(error) } }
            throw Failure.engine(
                error.map { String(cString: $0) } ?? "translation failed")
        }
        defer { murmur_ct2_string_free(out) }
        return String(cString: out)
    }
}
