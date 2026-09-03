import Foundation

/// Presents several sequential downloads as one bar.
///
/// A pivot route is two model downloads, but the user picked a language, not a
/// routing strategy, so they should see one bar. The legs are weighted by their
/// real size: `ruen` is 17 MB and `enru` is 43 MB, and treating those as two
/// halves would show 50% when 28% of the bytes had moved, then reset the byte
/// counter partway through.
///
/// This exists as a value rather than arithmetic inlined at the call site
/// specifically so the weighting is testable. An equal-weight regression is
/// invisible to any test that only reads sizes out of the manifest — it has to
/// be caught by exercising the combination itself.
public struct CombinedDownloadProgress: Equatable, Sendable {
    /// Total bytes for each leg, in the order they will be fetched.
    public let legBytes: [Int64]

    public init(legBytes: [Int64]) {
        self.legBytes = legBytes
    }

    /// Bytes across every leg.
    public var totalBytes: Int64 { legBytes.reduce(0, +) }

    /// Where the bar stands while `leg` has taken `received` of its own bytes.
    ///
    /// Out-of-range legs and over-long receives are clamped rather than
    /// trapped: this drives a progress bar, and a transfer that reports a few
    /// bytes more than pinned is legitimate — a mirror may re-compress the same
    /// verified content.
    public func at(leg: Int, received: Int64) -> (receivedBytes: Int64, fraction: Double) {
        guard !legBytes.isEmpty, leg >= 0 else { return (0, 0) }
        let index = min(leg, legBytes.count)
        let completed = legBytes[..<index].reduce(0, +)
        let capped = index < legBytes.count
            ? min(max(received, 0), legBytes[index])
            : 0
        let total = totalBytes
        let cumulative = min(completed + capped, total)
        guard total > 0 else { return (cumulative, 0) }
        return (cumulative, Double(cumulative) / Double(total))
    }
}
