import Foundation

public struct RecordedUtterance: Identifiable, Codable, Hashable, Sendable {
    public let id: UInt64
    public let startSample: Int
    public var endSample: Int
    public var text: String
    public var translation: String?
    public var settled: Bool
    public var translationFailed: Bool?
    public init(id: UInt64, startSample: Int, endSample: Int, text: String, translation: String? = nil, settled: Bool = false) {
        self.id = id; self.startSample = startSample; self.endSample = endSample
        self.text = text; self.translation = translation; self.settled = settled
    }
}

public struct UtteranceTranslation: Sendable {
    public let id: UInt64
    public let source: String
    public let text: String
    public let isFinal: Bool
    public let failed: Bool
    public init(id: UInt64, source: String, text: String, isFinal: Bool, failed: Bool = false) {
        self.id = id; self.source = source; self.text = text; self.isFinal = isFinal; self.failed = failed
    }
}

/// Durable conversation content is independent of any visible caption window.
/// A correction replaces only the audio ranges it covers, never the whole log.
public struct RecordingTranscript: Sendable {
    public private(set) var utterances: [RecordedUtterance] = []
    public private(set) var provisional = ""
    public private(set) var revision: UInt64 = 0
    private var receivedSnapshot = false
    private var settledBoundary = -1
    private var settledIDs: Set<UInt64> = []
    private var finished = false
    public init() {}
    public var hasSnapshots: Bool { receivedSnapshot }
    public var text: String { (utterances.map(\.text) + [provisional]).filter { !$0.isEmpty }.joined(separator: " ") }
    public var translatedText: String { utterances.compactMap(\.translation).filter { !$0.isEmpty }.joined(separator: " ") }

    @discardableResult public mutating func apply(_ snapshot: CaptionSnapshot) -> Bool {
        guard !finished, !receivedSnapshot || snapshot.revision > revision || (snapshot.revision == revision && (snapshot.settledThroughSample ?? -1) > settledBoundary) else { return false }
        receivedSnapshot = true; revision = snapshot.revision; provisional = snapshot.provisional
        settledBoundary = max(settledBoundary, snapshot.settledThroughSample ?? -1)
        var changedEntries = false
        for segment in snapshot.confirmed {
            if settledIDs.contains(segment.id) { continue }
            guard let end = segment.endSample, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // A late shorter result cannot restore an ID already covered by a later correction.
            if utterances.contains(where: { $0.id > segment.id && $0.startSample <= segment.startSample && $0.endSample >= end }) { continue }
            if let old = utterances.first(where: { $0.id == segment.id }), old.settled { continue }
            let previous = utterances.first { $0.id == segment.id && $0.text == segment.text }
            utterances.removeAll { !$0.settled && ($0.id == segment.id || ($0.id < segment.id && $0.startSample >= segment.startSample && $0.endSample <= end)) }
            utterances.append(.init(id: segment.id, startSample: segment.startSample, endSample: end,
                                    text: segment.text, translation: previous?.translation,
                                    settled: end <= settledBoundary))
            changedEntries = true
        }
        if changedEntries { utterances.sort { $0.startSample == $1.startSample ? $0.id < $1.id : $0.startSample < $1.startSample } }
        if let boundary = snapshot.settledThroughSample {
            for index in utterances.indices where utterances[index].endSample <= boundary {
                utterances[index].settled = true
                settledIDs.insert(utterances[index].id)
            }
        }
        return true
    }
    public mutating func applyTranslations(_ values: [UtteranceTranslation]) {
        for value in values where value.isFinal {
            guard let index = utterances.firstIndex(where: { $0.id == value.id && $0.text == value.source }) else { continue }
            utterances[index].translation = value.failed ? nil : value.text
            utterances[index].translationFailed = value.failed
        }
    }
    public mutating func finish(fallback: String, endSample: Int) {
        guard !finished else { return }
        if utterances.isEmpty && !fallback.isEmpty {
            utterances = [.init(id: 0, startSample: 0, endSample: endSample, text: fallback, settled: true)]
        } else if !provisional.isEmpty {
            let start = utterances.last?.endSample ?? 0
            utterances.append(.init(id: (utterances.map(\.id).max() ?? 0) + 1, startSample: start,
                                    endSample: max(start, endSample), text: provisional, settled: true))
        }
        for index in utterances.indices { utterances[index].settled = true; settledIDs.insert(utterances[index].id) }
        provisional = ""; finished = true
    }
}
