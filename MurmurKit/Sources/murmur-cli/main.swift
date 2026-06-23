import Foundation
import MurmurKit

// murmur-cli — the same dictation core as the menu-bar app, driven from the
// terminal: load + warm up, capture until you press Enter, print the transcript.
// Handy for profiling/comparison because it runs the identical MurmurKit pipeline.

let session = DictationSession()

// Echo only newly-confirmed text (like the app), so output isn't an O(n²) flood.
var lastConfirmed = ""
session.onUpdate = { confirmed, _ in
    guard confirmed.hasPrefix(lastConfirmed), confirmed.count > lastConfirmed.count else {
        lastConfirmed = confirmed
        return
    }
    FileHandle.standardError.write(Data(confirmed.suffix(confirmed.count - lastConfirmed.count).utf8))
    lastConfirmed = confirmed
}

FileHandle.standardError.write(Data("loading models (warming up MLX)…\n".utf8))
try await session.load()

try session.start()
FileHandle.standardError.write(Data("\nREADY: speak now — press Enter to stop.\n".utf8))
_ = readLine()

let final = session.stop()
print("\n\nFINAL: \(final)")
