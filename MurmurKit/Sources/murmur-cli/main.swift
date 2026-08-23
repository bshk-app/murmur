@preconcurrency import AVFoundation
import Foundation
import MurmurKit

// murmur-cli — the same dictation core (MurmurKit) as the menu-bar app.
//   murmur-cli                  → live mic: speak, press Enter, print transcript
//   murmur-cli --wav <file>     → offline benchmark on a fixed file (timing/RTF)
//   murmur-cli --wav <file> --mode fast|hybrid|accurate
//                               → benchmark one lane, to see which one costs what

let args = CommandLine.arguments
let session = DictationSession()

/// Which lane(s) to benchmark. Defaults to hybrid — what the app actually runs.
let benchMode: DictationMode = {
    guard let i = args.firstIndex(of: "--mode"), i + 1 < args.count,
          let m = DictationMode(rawValue: args[i + 1]) else { return .hybrid }
    return m
}()

/// Language prompt for Nemotron. `auto` is the model default; pass `--language ru`
/// to reproduce Murmur's Russian live lane.
let benchLanguage: String = {
    guard let i = args.firstIndex(of: "--language"), i + 1 < args.count else { return "auto" }
    return args[i + 1]
}()

/// Producer chunk. Defaults to the GUI's 96 ms; `--feed-ms` is benchmark-only.
let benchChunkSamples: Int = {
    guard let i = args.firstIndex(of: "--feed-ms"), i + 1 < args.count,
          let milliseconds = Int(args[i + 1]), milliseconds > 0 else {
        return DictationSession.liveChunkSamples
    }
    return milliseconds * 16
}()

/// Machine-readable output, for a benchmark host adapter to parse.
///
/// The human format is for reading; anything that scores results needs fields,
/// and it needs the configuration alongside them — a transcript without the
/// chunk size and delay that produced it cannot be compared with another run
/// without someone holding the mapping in their head.
/// Where the JSON goes. stdout is shared with whatever the model layer decides to
/// print — `Using cached model at: …` lands there — so a parser reading stdout
/// gets prose before the object. `--json-out <path>` writes the object and
/// nothing else, which is what a benchmark host should consume.
let jsonOutPath: String? = {
    guard let i = args.firstIndex(of: "--json-out"), i + 1 < args.count else { return nil }
    return args[i + 1]
}()

/// Asking for a destination is asking for the format: requiring `--json` as well
/// meant `--json-out path` silently produced the human output and no file.
let emitJSON = args.contains("--json") || jsonOutPath != nil

/// Timed passes per run, after loading the models once.
///
/// A single pass is not a measurement: the same binary on the same clip has
/// produced RTF from 4.4 to 10.4 on one machine. Repeats share the model load,
/// so three passes cost far less than three invocations, and we report the
/// MINIMUM — the pass least contaminated by whatever else the machine was doing.
let benchRepeats: Int = {
    guard let i = args.firstIndex(of: "--repeat"), i + 1 < args.count,
          let n = Int(args[i + 1]), n > 0 else { return 1 }
    return n
}()

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


/// One JSON line per run: transcript, timings, and the configuration identity.
func emitRunJSON(engine: String, identity: String, path: String, text: String,
                 audio: Double, compute: Double, rtf: Double, passes: Int) {
    let obj: [String: Any] = [
        "engine": engine,
        "clip": (path as NSString).lastPathComponent,
        "text": text,
        "audio_seconds": audio,
        "compute_seconds": compute,
        "rtfx": audio > 0 ? audio / compute : 0,   // throughput, not latency
        "rtf": rtf,
        "passes": passes,
        "identity": identity,
    ]
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let line = String(data: d, encoding: .utf8) else { return }
    if let path = jsonOutPath {
        try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    } else {
        print(line)
    }
}

/// Repo override, tolerating `--repo` with nothing after it instead of trapping.
let repoOverride: String? = {
    guard let i = args.firstIndex(of: "--repo"), i + 1 < args.count else { return nil }
    return args[i + 1]
}()

/// Read one newline-terminated header from stdin; nil at EOF.
func readHeaderLine(_ fh: FileHandle) -> String? {
    var bytes: [UInt8] = []
    while true {
        let d = fh.readData(ofLength: 1)
        if d.isEmpty { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
        if d[0] == 0x0A { return String(decoding: bytes, as: UTF8.self) }
        bytes.append(d[0])
    }
}

/// Read exactly `n` bytes, or nil if the stream ends first. A short read is not
/// an error from a pipe — it just means the writer hasn't caught up yet.
func readExactly(_ n: Int, from fh: FileHandle) -> Data? {
    var out = Data()
    while out.count < n {
        let d = fh.readData(ofLength: n - out.count)
        if d.isEmpty { return nil }
        out.append(d)
    }
    return out
}

if args.contains("--serve-stream") {
    // ---- Producer-paced streaming worker ----
    //
    // The benchmark producer feeds audio at 1x real time and timestamps the first
    // partial itself, so the host cannot self-report latency. Framing on stdin:
    //
    //     "C <byteCount>\n" + byteCount bytes of float32 LE  -> {"partial": "..."}
    //     "F\n"                                              -> {"text": "..."}
    //
    // One reply per request, always — see StreamServeLoop.
    let realOut = dup(1)
    dup2(2, 1)
    let out = FileHandle(fileDescriptor: realOut, closeOnDealloc: false)
    let input = FileHandle.standardInput

    let step: ([Float]) -> String
    let finish: () -> String
    if args.contains("--parakeet") {
        let ane = args.contains("--ane")
        let repo = repoOverride ?? ParakeetProbe.defaultRepo
        FileHandle.standardError.write(Data("loading \(repo) (ane: \(ane))…\n".utf8))
        let streamer = try await ParakeetStreamer.make(repo: repo, ane: ane)
        step = { streamer.step($0) }
        finish = { streamer.finish() }
    } else {
        FileHandle.standardError.write(Data("loading models for mode \(benchMode.rawValue)…\n".utf8))
        try await session.load(mode: benchMode)
        var started = false
        step = {
            if !started { session.beginPaced(mode: benchMode, language: benchLanguage); started = true }
            return session.stepPaced($0)
        }
        finish = {
            defer { started = false }              // the next chunk is a new utterance
            return started ? session.finishPaced() : ""
        }
    }

    FileHandle.standardError.write(Data("\nREADY\n".utf8))
    StreamServeLoop.run(
        next: {
            guard let header = readHeaderLine(input) else { return nil }
            if header == "F" { return .finish }
            guard header.hasPrefix("C "), let n = Int(header.dropFirst(2)),
                  let data = readExactly(n, from: input) else { return nil }
            return .chunk(data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
        },
        step: step,
        finish: finish,
        write: { out.write(Data(($0 + "\n").utf8)) }
    )
} else if args.contains("--serve") {
    // ---- Worker mode: one path per line in, one JSON object per line out ----
    //
    // A benchmark host calls the transcriber once per sample and times the call.
    // Loading the model per sample would put ~10 s of load into every ~30 s
    // Voxtral measurement, so it loads once here and samples arrive over a pipe.
    //
    // Take a private handle on the real stdout BEFORE anything can print to it,
    // then point fd 1 at stderr: the model layer writes "Using cached model at: …"
    // to stdout, and a client parsing one object per line would choke on prose.
    // Redirecting is better than a sentinel prefix — it holds for any library
    // that decides to print, not just the ones we know about today.
    let realOut = dup(1)
    dup2(2, 1)
    let out = FileHandle(fileDescriptor: realOut, closeOnDealloc: false)

    let transcribe: (String) throws -> String
    if args.contains("--parakeet") {
        let ane = args.contains("--ane")
        let repo = repoOverride ?? ParakeetProbe.defaultRepo
        FileHandle.standardError.write(Data("loading \(repo) (ane: \(ane))…\n".utf8))
        let run = try await ParakeetProbe.makeTranscriber(repo: repo, ane: ane)
        transcribe = { run(try readWav16kMono($0)) }
    } else {
        FileHandle.standardError.write(Data("loading models for mode \(benchMode.rawValue)…\n".utf8))
        try await session.load(mode: benchMode)
        transcribe = {
            session.transcribeOffline(
                try readWav16kMono($0), mode: benchMode, language: benchLanguage
            ).text
        }
    }

    FileHandle.standardError.write(Data("\nREADY\n".utf8))
    BatchServeLoop.run(
        readLine: { Swift.readLine(strippingNewline: true) },
        transcribe: transcribe,
        write: { out.write(Data(($0 + "\n").utf8)) }
    )
} else if let pIdx = args.firstIndex(of: "--parakeet"), pIdx + 1 < args.count {
    // ---- Parakeet comparison probe: is a 0.6B TDT lane on the ANE enough? ----
    let path = args[pIdx + 1]
    let samples = try readWav16kMono(path)
    let ane = args.contains("--ane")
    let repo = repoOverride ?? ParakeetProbe.defaultRepo
    FileHandle.standardError.write(Data("loading \(repo) (ane: \(ane))…\n".utf8))
    let r = try await ParakeetProbe.transcribe(samples, repo: repo, ane: ane, passes: benchRepeats)
    if emitJSON {
        // Only what shaped THIS run. Carrying the two-tier lane's chunk and delay
        // here would make two identical Parakeet runs look different whenever an
        // unrelated Nemotron setting changed — the opposite of what identity is for.
        let engine = ane ? "parakeet-ane" : "parakeet-mlx"
        emitRunJSON(engine: engine, identity: "engine=\(engine);repo=\(repo)",
                    path: path, text: r.text,
                    audio: r.audioSeconds, compute: r.computeSeconds, rtf: r.rtf, passes: r.passes)
    } else {
    print(String(format: """

        === parakeet %@ (encoder: %@, %d pass(es)) ===
        audio    %.2f s
        compute  %.2f s
        wall     %.2f s
        audio_processed %.2f s
        RTF_MIN  %.3f     (<1 = faster than realtime)
        """, (path as NSString).lastPathComponent, ane ? "ANE" : "MLX", r.passes,
             r.audioSeconds, r.computeSeconds, r.wallSeconds, r.audioProcessedSeconds, r.rtf))
    print("\ntext: \(r.text)")
    }
} else if args.contains("--captions"), let wavIdx = args.firstIndex(of: "--wav"), wavIdx + 1 < args.count {
    // ---- Captions on a fixed file: phrase segmentation and correction latency ----
    let path = args[wavIdx + 1]
    let samples = try readWav16kMono(path)
    let captions = CaptionSession()
    FileHandle.standardError.write(Data("loading models + Silero (warming up MLX)…\n".utf8))
    try await captions.load()
    // The safety cap is the rarest path in production — natural speech pauses long
    // before 60 s — so `--cap-s` shortens it to exercise that seam many times.
    let capSeconds: Double = {
        guard let i = args.firstIndex(of: "--cap-s"), i + 1 < args.count,
              let s = Double(args[i + 1]), s > 0 else { return CaptionSession.defaultMaxEpochSeconds }
        return s
    }()
    FileHandle.standardError.write(Data(String(
        format: "captioning %.1fs of audio (\(benchChunkSamples / 16) ms chunks, language: %@, cap %.0fs)…\n",
        Double(samples.count) / 16000.0, benchLanguage, capSeconds).utf8))
    // Report each phrase as it is corrected: that is the event the overlay shows.
    // The gap from the previous phrase is printed rather than guessed at from the
    // phrase length — 0.000 means the seam was cut mid-speech (the cap), and any
    // negative value would mean two passes were handed the same audio.
    //
    // Tracked by segment id, NOT by list length: the overlay keeps only the last
    // `confirmedHistory` phrases, so on a long talk the count plateaus and a
    // length-based guard silently stops reporting — hiding exactly the later part
    // of the run an analysis needs.
    var lastID: UInt64 = 0
    var printed = 0
    var lastEnd: Double?
    var reporting = true
    captions.onSnapshot = { snapshot in
        guard reporting else { return }
        for segment in snapshot.confirmed where segment.id > lastID && segment.state == .confirmed {
            let start = Double(segment.startSample) / 16_000.0
            let end = Double(segment.endSample ?? segment.startSample) / 16_000.0
            let gap = lastEnd.map { String(format: "%+.3f", start - $0) } ?? "  —   "
            print(String(format: "[%7.3f–%7.3f] gap %@ %@", start, end, gap, segment.text))
            lastID = segment.id
            lastEnd = end
            printed += 1
        }
    }
    // RTF on a shared machine swings by 2x, so take the best of N passes like the
    // dictation bench does. Only the first pass reports phrases.
    var results: [CaptionOfflineResult] = []
    for pass in 1 ... benchRepeats {
        results.append(captions.captionOffline(samples, chunkSamples: benchChunkSamples,
                                               language: benchLanguage, maxEpochSeconds: capSeconds))
        reporting = false
        FileHandle.standardError.write(Data(
            String(format: "  pass %d/%d: RTF %.3f\n", pass, benchRepeats, results[pass - 1].rtf).utf8))
    }
    let r = results.min { $0.rtf < $1.rtf }!
    print(String(format: """

        === murmur-cli --captions %@ ===
        audio    %.2f s
        compute  %.2f s
        RTF      %.3f     (<1 = faster than realtime)
        phrases  %d          (overlay retains the last %d)
        """, (path as NSString).lastPathComponent,
             r.audioSeconds, r.computeSeconds, r.rtf, printed, r.snapshot.confirmed.count))
    // The whole talk, not the overlay's window: `text` is what the retained
    // segments say, so a long run needs the phrases as they were reported.
    print("\nretained tail: \(r.text)")
} else if let wavIdx = args.firstIndex(of: "--wav"), wavIdx + 1 < args.count {
    // ---- Offline benchmark on a fixed file ----
    let path = args[wavIdx + 1]
    let samples = try readWav16kMono(path)
    FileHandle.standardError.write(Data("loading models (warming up MLX)…\n".utf8))
    try await session.load(mode: benchMode)
    FileHandle.standardError.write(Data(String(
        format: "transcribing %.1fs of audio (\(benchChunkSamples / 16) ms chunks, mode: %@, language: %@)…\n",
        Double(samples.count) / 16000.0, benchMode.rawValue, benchLanguage).utf8))
    var results: [OfflineResult] = []
    for pass in 1 ... benchRepeats {
        results.append(session.transcribeOffline(
            samples, chunkSamples: benchChunkSamples, mode: benchMode, language: benchLanguage
        ))
        FileHandle.standardError.write(Data(
            String(format: "  pass %d/%d: RTF %.3f\n", pass, benchRepeats, results[pass - 1].rtf).utf8))
    }
    let best = results.min { $0.rtf < $1.rtf }!
    if emitJSON {
        // Each lane carries only its own knobs.
        var parts = ["engine=\(benchMode.rawValue)"]
        if benchMode != .accurate {
            parts.append("chunk_ms=\(TwoTierEngine.defaultFastChunkMs)")
            parts.append("language=\(benchLanguage)")
            parts.append("feed_ms=\(benchChunkSamples / 16)")
        }
        if benchMode != .fast { parts.append("parakeet_chunk_s=\(Int(TwoTierEngine.finalChunkDuration))") }
        emitRunJSON(engine: benchMode.rawValue, identity: parts.joined(separator: ";"),
                    path: path, text: best.text,
                    audio: best.audioSeconds, compute: best.computeSeconds,
                    rtf: best.rtf, passes: benchRepeats)
    } else {
    print(String(format: """

        === murmur-cli --wav %@ (mode %@, %d pass(es)) ===
        audio    %.2f s
        compute  %.2f s   (sum of step+finish, best pass)
        RTF_MIN  %.3f     (<1 = faster than realtime)
        """, (path as NSString).lastPathComponent, benchMode.rawValue, benchRepeats,
             best.audioSeconds, best.computeSeconds, best.rtf))
    print("\ntext: \(best.text)")
    }
} else {
    // ---- Live mic ----
    // Nemotron draft is redrawn in place; Parakeet supplies the final on stop.
    // Showing the last ~100 chars keeps it to one terminal line (no flood).
    session.onUpdate = { confirmed, partial in
        let line = partial.isEmpty ? confirmed : "\(confirmed) ⟨\(partial)⟩"
        let tail = line.count > 100 ? "…" + String(line.suffix(100)) : line
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(tail)".utf8))
    }

    FileHandle.standardError.write(Data("loading models (warming up MLX)…\n".utf8))
    try await session.load(mode: benchMode)
    try session.start(mode: benchMode, language: benchLanguage)
    FileHandle.standardError.write(Data("\nREADY: speak now — press Enter to stop.\n".utf8))
    _ = readLine()
    let final = session.stop()
    print("\n\nFINAL: \(final)")
}
