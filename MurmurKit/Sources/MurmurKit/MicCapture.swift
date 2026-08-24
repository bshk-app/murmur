@preconcurrency import AVFoundation
import Foundation

/// Captures the selected input (or the current system default) and resamples to
/// 16 kHz mono Float, delivering fixed 96 ms chunks via `onChunk`
/// (1536 samples = 3 Silero frames).
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

    // 96 ms @ 16 kHz. Hybrid now only runs Nemotron live, so the old 480 ms
    // feed (a two-model MLX-overhead workaround) is no longer required.
    private let chunkSize = DictationSession.liveChunkSamples
    private let queue = DispatchQueue(label: "murmur.mic.capture")
    private let engine = AVAudioEngine()
    private let inputDeviceUID: String?
    private var converter: AVAudioConverter?
    private var outFmt: AVAudioFormat?

    private var pending: [Float] = []
    private var totalSamples = 0
    private var peak: Float = 0

    init(inputDeviceUID: String? = nil) {
        self.inputDeviceUID = inputDeviceUID
    }

    func start() throws {
        queue.sync { pending.removeAll(keepingCapacity: true); totalSamples = 0; peak = 0 }

        try AudioInputDevices.route(preferredUID: inputDeviceUID, on: engine)
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

    /// Stop capture, drain the resampler, flush the trailing partial chunk, and
    /// report what was heard.
    func stop() -> Result {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let converter, let outFmt {
            enqueue(Self.drain(converter, outputFormat: outFmt))
        }
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
        enqueue(Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))))
    }

    private func enqueue(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        var sum: Float = 0
        for value in chunk { sum += value * value }
        let rms = (sum / Float(chunk.count)).squareRoot()
        queue.async { [self] in
            totalSamples += chunk.count
            if rms > peak { peak = rms }
            pending.append(contentsOf: chunk)
            while pending.count >= chunkSize {
                let next = Array(pending.prefix(chunkSize))
                pending.removeFirst(chunkSize)
                onChunk(next)
            }
        }
    }

    static func drain(_ converter: AVAudioConverter, outputFormat: AVAudioFormat) -> [Float] {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else {
            return []
        }
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        guard error == nil, output.frameLength > 0, let channel = output.floatChannelData else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
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
