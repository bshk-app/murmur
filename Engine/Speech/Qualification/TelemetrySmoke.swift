import Foundation

/// Model-free host test; this does not produce release qualification evidence.
@main struct TelemetrySmoke {
    static func main() throws {
        let telemetry = SpeechQualificationTelemetry()
        telemetry.reset()
        assert(telemetry.snapshot().firstPreviewSeconds == nil)
        telemetry.audioQueued(2)
        telemetry.audioQueued(-1)
        telemetry.pendingCorrections(3)
        telemetry.pendingCorrections(1)
        telemetry.observedPreview()
        telemetry.observedPreview()
        telemetry.correctionFailed()
        telemetry.finished(since: ProcessInfo.processInfo.systemUptime)
        let sample = telemetry.snapshot()
        assert(sample.pendingAudioChunks == 1 && sample.peakPendingAudioChunks == 2)
        assert(sample.pendingCorrections == 1 && sample.peakPendingCorrections == 3)
        assert(sample.previewUpdates == 2 && sample.firstPreviewSeconds != nil)
        assert(sample.maxPreviewUpdateGapSeconds != nil && sample.correctionFailures == 1)
        assert(sample.finalizationSeconds != nil)
        assert((sample.processFootprintBytes ?? 0) > 0)
        _ = try JSONDecoder().decode(SpeechQualificationSnapshot.self, from: JSONEncoder().encode(sample))
        telemetry.reset()
        assert(telemetry.snapshot().previewUpdates == 0)
        assert(telemetry.snapshot().pendingAudioChunks == 0)
        print("TelemetrySmoke passed (host process only; not device qualification)")
    }
}
