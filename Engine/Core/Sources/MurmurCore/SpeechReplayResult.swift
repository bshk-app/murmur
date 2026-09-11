import Foundation
public struct SpeechReplayResult: Sendable {
    public let text: String
    public let audioSeconds: Double
    public let computeSeconds: Double
    public let wallSeconds: Double
    public var rtf: Double { audioSeconds > 0 ? computeSeconds / audioSeconds : 0 }
    public init(text: String, audioSeconds: Double, computeSeconds: Double, wallSeconds: Double) { self.text=text; self.audioSeconds=audioSeconds; self.computeSeconds=computeSeconds; self.wallSeconds=wallSeconds }
}
