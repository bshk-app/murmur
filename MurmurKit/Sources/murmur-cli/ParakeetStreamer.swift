import Foundation
import MLXAudioSTT

/// Bench-only rolling streamer. Lives in murmur-cli so the app target does not
/// depend on `ParakeetStreamSession`, which the Xcode-resolved package pin
/// does not expose.
enum ParakeetStreamer {
    final class Session {
        private let model: ParakeetModel
        private var session: ParakeetStreamSession?
        private let configuration: ParakeetStreamingConfiguration

        init(model: ParakeetModel, configuration: ParakeetStreamingConfiguration) {
            self.model = model
            self.configuration = configuration
        }

        func step(_ samples: [Float]) -> String {
            if session == nil {
                do { session = try model.makeStreamSession(configuration: configuration) } catch {
                    FileHandle.standardError.write(
                        Data("stream session failed: \(error)\n".utf8))
                    return ""
                }
            }
            return session?.step(samples)?.text ?? ""
        }

        func finish() -> String {
            defer { session = nil }
            return session?.finish().text ?? ""
        }
    }

    static func make(repo: String, ane: Bool) async throws -> Session {
        let model = try await ParakeetModel.fromPretrained(repo, aneEncoder: ane ? .on : .off)
        let configuration = ParakeetStreamingConfiguration()
        _ = try model.makeStreamSession(configuration: configuration)
        return Session(model: model, configuration: configuration)
    }
}
