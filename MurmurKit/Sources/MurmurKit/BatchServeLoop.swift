import Foundation

/// One-path-in, one-JSON-line-out worker loop.
///
/// Exists because a benchmark host calls the transcriber once per sample and
/// times the call. Spawning a process per sample would charge every measurement
/// for loading the model — around 10 s of the ~30 s a Voxtral sample takes — so
/// the model loads once and the caller feeds paths down a pipe.
///
/// The contract the client depends on: **exactly one line out per non-blank line
/// in**. A client blocks on its reply, so a sample that fails must still answer
/// or the whole run deadlocks on the first bad file.
public enum BatchServeLoop {
    public static func run(
        readLine: () -> String?,
        transcribe: (String) throws -> String,
        write: (String) -> Void
    ) {
        while let raw = readLine() {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty { continue }          // a trailing newline is not a request
            let clip = (path as NSString).lastPathComponent
            do {
                write(encode(["clip": clip, "text": try transcribe(path)]))
            } catch {
                write(encode(["clip": clip, "error": String(describing: error)]))
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
