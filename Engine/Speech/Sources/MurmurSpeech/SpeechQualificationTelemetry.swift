import Foundation
import Darwin

/// Monotonic host observations. Sampled footprint is the complete process, not
/// the MLX allocator; it is a sampled peak, not a guarantee of the true peak.
public struct SpeechQualificationSnapshot: Codable, Sendable {
    public let elapsedSeconds: Double
    public let firstPreviewSeconds: Double?
    public let previewUpdates: Int
    public let maxPreviewUpdateGapSeconds: Double?
    public let correctionFailures: Int
    public let finalizationSeconds: Double?
    public let maxInputScheduleLagSeconds: Double
    public let pendingAudioChunks: Int
    public let peakPendingAudioChunks: Int
    public let pendingCorrections: Int
    public let peakPendingCorrections: Int
    public let processFootprintBytes: UInt64?
    public let sampledPeakProcessFootprintBytes: UInt64?
}

final class SpeechQualificationTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var started = ProcessInfo.processInfo.systemUptime
    private var preview: Double?
    private var lastPreview: Double?
    private var previewUpdates = 0
    private var maxPreviewGap: Double?
    private var failures = 0
    private var finalization: Double?
    private var audio = 0, peakAudio = 0, corrections = 0, peakCorrections = 0
    private var maxInputLag = 0.0
    private var footprintPeak: UInt64?
    func reset() {
        lock.lock(); defer { lock.unlock() }
        started = ProcessInfo.processInfo.systemUptime
        preview = nil; lastPreview = nil; previewUpdates = 0; maxPreviewGap = nil; failures = 0; finalization = nil; audio = 0; peakAudio = 0
        corrections = 0; peakCorrections = 0; footprintPeak = nil; maxInputLag = 0
    }
    func observedPreview() {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if preview == nil { preview = now - started }
        if let lastPreview { maxPreviewGap = max(maxPreviewGap ?? 0, now - lastPreview) }
        lastPreview = now; previewUpdates += 1
    }
    func correctionFailed() {
        lock.lock(); defer { lock.unlock() }; failures += 1
    }
    func inputScheduleLag(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }; maxInputLag = max(maxInputLag, seconds)
    }
    func audioQueued(_ delta: Int) {
        lock.lock(); defer { lock.unlock() }
        audio = max(0, audio + delta); peakAudio = max(peakAudio, audio)
    }
    func pendingCorrections(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        corrections = count; peakCorrections = max(peakCorrections, count)
    }
    func finished(since start: Double) {
        lock.lock(); defer { lock.unlock() }
        finalization = ProcessInfo.processInfo.systemUptime - start
    }
    func snapshot() -> SpeechQualificationSnapshot {
        let bytes = Self.processFootprint()
        lock.lock(); defer { lock.unlock() }
        if let bytes { footprintPeak = max(footprintPeak ?? 0, bytes) }
        return SpeechQualificationSnapshot(elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
            firstPreviewSeconds: preview, previewUpdates: previewUpdates, maxPreviewUpdateGapSeconds: maxPreviewGap,
            correctionFailures: failures, finalizationSeconds: finalization,
            maxInputScheduleLagSeconds: maxInputLag, pendingAudioChunks: audio, peakPendingAudioChunks: peakAudio,
            pendingCorrections: corrections, peakPendingCorrections: peakCorrections,
            processFootprintBytes: bytes, sampledPeakProcessFootprintBytes: footprintPeak)
    }
    private static func processFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
