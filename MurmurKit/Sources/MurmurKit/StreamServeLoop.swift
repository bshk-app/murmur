import Foundation

/// Producer-paced streaming worker loop: one reply per request, forever.
///
/// The benchmark producer feeds audio at 1x real time and timestamps the first
/// partial itself, so latency is measured by the producer rather than claimed by
/// the host. That only works if the host answers every chunk — including a chunk
/// that produced no new text. Staying silent stalls the paced feed and is scored
/// as failing to drain the stream, so an empty partial is still a reply.
///
/// `finish` ends an utterance and returns the final transcript. One file is one
/// utterance: the next chunk after a finish belongs to a new recording, so the
/// caller's `finish` closure is responsible for starting a fresh session.
public enum StreamServeLoop {
    public enum Request {
        case chunk([Float])
        case finish
    }

    public static func run(
        next: () -> Request?,
        step: ([Float]) -> String,
        finish: () -> String,
        write: (String) -> Void
    ) {
        while let request = next() {
            switch request {
            case .chunk(let samples): write(encode(["partial": step(samples)]))
            case .finish:             write(encode(["text": finish()]))
            }
        }
    }

    /// One object on one line. JSONSerialization escapes newlines inside strings,
    /// so a multi-line transcript cannot split a reply in two.
    private static func encode(_ object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return #"{"error":"result could not be encoded"}"#
        }
        return line
    }
}
