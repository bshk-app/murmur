import Foundation

/// Reproducible runtime settings; promoting a profile requires qualification.
public struct TranslationDecodingProfile: Codable, Hashable, Sendable {
    public enum ComputeType: String, Codable, Hashable, Sendable { case int8, float32 }
    public var beamSize: Int
    public var maxSourcePieces: Int
    public var maxDecodingLength: Int
    public var lengthPenalty: Float
    public var computeType: ComputeType

    public static let baseline = TranslationDecodingProfile()

    public init(beamSize: Int = 1, maxSourcePieces: Int = 200,
                maxDecodingLength: Int = 512, lengthPenalty: Float = 1,
                computeType: ComputeType = .int8) {
        self.beamSize = beamSize
        self.maxSourcePieces = maxSourcePieces
        self.maxDecodingLength = maxDecodingLength
        self.lengthPenalty = lengthPenalty
        self.computeType = computeType
    }

    public enum ValidationError: Error { case invalidDecodingProfile }

    public func validate() throws {
        guard [1, 4, 6, 8].contains(beamSize), (1...512).contains(maxSourcePieces),
              (1...1024).contains(maxDecodingLength), lengthPenalty.isFinite,
              (0...3).contains(lengthPenalty) else {
            throw ValidationError.invalidDecodingProfile
        }
    }
}
