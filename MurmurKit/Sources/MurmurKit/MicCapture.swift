@preconcurrency import AVFoundation
import Foundation

/// Captures the default input and resamples to 16 kHz mono Float, delivering
/// fixed 80 ms chunks via `onChunk`. Ported from the mic-compare CLI's MicRunner.
///
/// `@unchecked Sendable`: the input-tap closure runs on the realtime audio
/// thread, so it must NOT inherit actor isolation. All mutable state is confined
/// to `queue`; a single stateful `AVAudioConverter` keeps resampler continuity.
final class MicCapture: @unchecked Sendable {
    struct Result {
        let sampleCount: Int
        let durationS: Double
        let peakRMS: Float
    }

    /// Fixed-size 16 kHz mono chunks delivered on the capture queue.
    var onChunk: ([Float]) -> Void = { _ in }

    // 480 ms per `session.step`, matching the mic-compare CLI's feedMs=480. This
    // is the FEED size, NOT Nemotron's internal chunk (that's
    // `TwoTierEngine.defaultFastChunkMs`, already set on the session) — feeding at
    // a smaller size calls step proportionally more often and the per-call MLX
    // overhead pushes RTF > 1 → backlog → freeze.
    private let chunkSize = 7680                          // 480 ms @ 16 kHz
    private let queue = DispatchQueue(label: "murmur.mic.capture")
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outFmt: AVAudioFormat?

    private var pending: [Float] = []
    private var totalSamples = 0
    private var peak: Float = 0

    func start() throws {
        queue.sync { pending.removeAll(keepingCapacity: true); totalSamples = 0; peak = 0 }

        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: out)
        else {
            throw NSError(domain: "Murmur.MicCapture", code: 1, userInfo:
                [NSLocalizedDescriptionKey: "could not build a 16 kHz mono converter from \(inFmt)"])
        }
        outFmt = out
        converter = conv

        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stop capture, flush the trailing partial chunk, and report what was heard.
    func stop() -> Result {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        return queue.sync {
            if !pending.isEmpty {
                onChunk(pending)
                pending.removeAll(keepingCapacity: true)
            }
            return Result(sampleCount: totalSamples,
                          durationS: Double(totalSamples) / 16000.0,
                          peakRMS: peak)
        }
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let outFmt, let converter else { return }
        let ratio = outFmt.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }

        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }

        let n = Int(out.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: ch[0], count: n))
        var sum: Float = 0
        for v in chunk { sum += v * v }
        let rms = (sum / Float(max(1, n))).squareRoot()

        queue.async { [self] in
            totalSamples += n
            if rms > peak { peak = rms }
            pending.append(contentsOf: chunk)
            while pending.count >= chunkSize {
                let c = Array(pending.prefix(chunkSize))
                pending.removeFirst(chunkSize)
                onChunk(c)
            }
        }
    }

    /// Mic TCC gate. Calls back on the main queue.
    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default:
            completion(false)
        }
    }
}
