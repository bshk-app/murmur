import Foundation

/// One caption phrase: the live model's draft, later replaced wholesale by the
/// batch model's text for the same audio range.
public struct CaptionSegment: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case provisional   // live draft, audio still open
        case awaitingBatch // range closed, batch pass not back yet
        case confirmed     // batch text, authoritative
    }

    public let id: UInt64
    public let startSample: Int
    public var endSample: Int?
    public var text: String
    public var state: State
    public init(id: UInt64, startSample: Int, endSample: Int?, text: String, state: State) {
        self.id = id; self.startSample = startSample; self.endSample = endSample; self.text = text; self.state = state
    }
}

/// What the caption overlay renders.
public struct CaptionSnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let confirmed: [CaptionSegment]
    public let provisional: String
    public let settledThroughSample: Int?
    public init(revision: UInt64, confirmed: [CaptionSegment], provisional: String, settledThroughSample: Int? = nil) {
        self.revision = revision; self.confirmed = confirmed; self.provisional = provisional; self.settledThroughSample = settledThroughSample
    }
}

/// Caption text as a list of segments keyed by id.
///
/// Corrections address a segment, never a character range, so a late batch
/// result cannot overwrite the phrase after it — and a pause landing
/// mid-sentence cannot duplicate words, because the batch text replaces the
/// whole segment instead of being spliced onto a prefix.
struct CaptionTranscript {
    private var segments: [CaptionSegment] = []
    private var nextID: UInt64 = 1
    private var revision: UInt64 = 0

    /// Open a segment for the audio starting at `startSample`.
    @discardableResult
    mutating func open(startSample: Int) -> UInt64 {
        let id = nextID
        nextID += 1
        segments.append(CaptionSegment(
            id: id, startSample: startSample, endSample: nil,
            text: "", state: .provisional
        ))
        revision += 1
        return id
    }

    /// Replace a segment's live draft. Ignored once the batch text has landed.
    mutating func updateProvisional(_ id: UInt64, text: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }),
              segments[index].state != .confirmed else { return }
        guard segments[index].text != text else { return }
        segments[index].text = text
        revision += 1
    }

    /// Mark the audio range closed; the batch pass owns the text from here.
    mutating func close(_ id: UInt64, endSample: Int) {
        guard let index = segments.firstIndex(where: { $0.id == id }),
              segments[index].state == .provisional else { return }
        segments[index].endSample = endSample
        segments[index].state = .awaitingBatch
        revision += 1
    }

    /// Install the batch transcript for a segment. An empty result keeps the
    /// draft: for captions an approximate line beats a blank one, and unlike
    /// dictation nothing is pasted or sent from it.
    mutating func confirm(_ id: UInt64, text: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { segments[index].text = text }
        segments[index].state = .confirmed
        revision += 1
    }

    /// A context pass may revise earlier closed segments, never newer speech.
    /// Keeping the newest covered ID also makes late shorter results harmless:
    /// their IDs have already been removed by the longer correction.
    mutating func confirm(_ id: UInt64, text: String, replacing ids: [UInt64]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { confirm(id, text: text); return }
        guard let last = segments.first(where: { $0.id == id }), last.endSample != nil else { return }
        let covered = Set(ids)
        let matches = segments.filter { covered.contains($0.id) && $0.id <= id && $0.endSample != nil }
        guard let start = matches.map(\.startSample).min() else { return }
        segments.removeAll { covered.contains($0.id) && $0.id < id && $0.endSample != nil }
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index] = CaptionSegment(id: id, startSample: start, endSample: last.endSample,
                                         text: trimmed, state: .confirmed)
        revision += 1
    }

    /// Drop confirmed history beyond `keep`, oldest first.
    mutating func trimConfirmed(keep: Int) {
        let confirmed = segments.filter { $0.state == .confirmed }
        guard confirmed.count > keep else { return }
        let drop = Set(confirmed.prefix(confirmed.count - keep).map(\.id))
        segments.removeAll { drop.contains($0.id) }
        revision += 1
    }

    func snapshot() -> CaptionSnapshot {
        let live = segments.last.flatMap { $0.state == .provisional ? $0.text : nil } ?? ""
        return CaptionSnapshot(
            revision: revision,
            confirmed: segments.filter { $0.state != .provisional },
            provisional: live
        )
    }
}
