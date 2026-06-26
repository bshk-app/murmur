@preconcurrency import AVFoundation
import Foundation
import MurmurKit

// murmur-cli — the same dictation core (MurmurKit) as the menu-bar app.
//   murmur-cli                  → live mic: speak, press Enter, print transcript
//   murmur-cli --wav <file>     → offline benchmark on a fixed file (timing/RTF)

let args = CommandLine.arguments
let session = DictationSession()

/// Read any audio file and resample to 16 kHz mono Float.
func readWav16kMono(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let inFmt = file.processingFormat
    guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                     channels: 1, interleaved: false),
          let conv = AVAudioConverter(from: inFmt, to: outFmt),
          let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length))
    else { throw NSError(domain: "murmur-cli", code: 1) }
    try file.read(into: inBuf)

    let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16000.0 / inFmt.sampleRate) + 1024
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return [] }
    var done = false
    var err: NSError?
    conv.convert(to: outBuf, error: &err) { _, status in
        if done { status.pointee = .noDataNow; return nil }
        done = true; status.pointee = .haveData; return inBuf
    }
    guard err == nil, let ch = outBuf.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
}

if let wavIdx = args.firstIndex(of: "--wav"), wavIdx + 1 < args.count {
    // ---- Offline benchmark on a fixed file ----
    let path = args[wavIdx + 1]
    let samples = try readWav16kMono(path)
    FileHandle.standardError.write(Data("loading models (warming up MLX)…\n".utf8))
    try await session.load()
    FileHandle.standardError.write(Data(
        String(format: "transcribing %.1fs of audio (480 ms chunks)…\n", Double(samples.count) / 16000.0).utf8))
    let r = session.transcribeOffline(samples)
    print(String(format: """

        === murmur-cli --wav %@ ===
        audio    %.2f s
        compute  %.2f s   (sum of step+finish)
        wall     %.2f s
        RTF      %.3f     (<1 = faster than realtime)
        """, (path as NSString).lastPathComponent, r.audioSeconds, r.computeSeconds, r.wallSeconds, r.rtf))
    print("\ntext: \(r.text)")
} else {
    // ---- Live mic ----
    // Live two-tier view, redrawn in place: confirmed (Voxtral) prefix + the fast
    // Nemotron tail in ⟨⟩, which arrives ~960 ms ahead of the finals. Showing the
    // last ~100 chars keeps it to one terminal line (no flood).
    session.onUpdate = { confirmed, partial in
        let line = partial.isEmpty ? confirmed : "\(confirmed) ⟨\(partial)⟩"
        let tail = line.count > 100 ? "…" + String(line.suffix(100)) : line
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(tail)".utf8))
    }

    FileHandle.standardError.write(Data("loading models (warming up MLX)…\n".utf8))
    try await session.load()
    try session.start()
    FileHandle.standardError.write(Data("\nREADY: speak now — press Enter to stop.\n".utf8))
    _ = readLine()
    let final = session.stop()
    print("\n\nFINAL: \(final)")
}
