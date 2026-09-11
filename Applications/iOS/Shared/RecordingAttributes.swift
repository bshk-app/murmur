import ActivityKit
import Foundation

struct RecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable { var phase: String }
    let startedAt: Date
    var keyboard: Bool? = nil
}
