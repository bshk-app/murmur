import Foundation

/// Presentation-only word diff. Never changes the transcript or matching of audio segments.
public struct CorrectionDisplay: Equatable {
    public enum Tone: Equatable { case draft, confirmed, changed }
    public struct Run: Equatable {
        public let text: String
        public let tone: Tone
    }
    public private(set) var text = ""
    public private(set) var runs: [Run] = []
    public private(set) var correctionRevision = 0
    public var hasChanges: Bool { runs.contains { $0.tone == .changed } }
    private var lastRevision: UInt64?
    private var confirmed: [CaptionSegment] = []
    private var finalized = false
    private var highlighted: Set<Int> = []
    private static let tokenizer = try! NSRegularExpression(pattern: #"\s+|\S+"#)
    private struct Token { let text: String; let range: NSRange }
    public init() {}

    @discardableResult public mutating func update(_ snapshot: CaptionSnapshot) -> Bool {
        guard !finalized, lastRevision.map({ snapshot.revision > $0 }) ?? true else { return false }
        lastRevision = snapshot.revision
        let nextConfirmed = snapshot.confirmed.filter { $0.state == .confirmed }
        var nextText = ""
        var ranges: [NSRange] = []
        var utf16Offset = 0
        for phrase in snapshot.confirmed where !phrase.text.isEmpty {
            if !nextText.isEmpty { nextText += " "; utf16Offset += 1 }
            let start = utf16Offset
            nextText += phrase.text
            let length = phrase.text.utf16.count
            utf16Offset += length
            if phrase.state == .confirmed { ranges.append(NSRange(location: start, length: length)) }
        }
        if !snapshot.provisional.isEmpty {
            if !nextText.isEmpty { nextText += " " }
            nextText += snapshot.provisional
        }
        apply(nextText, confirmedRanges: ranges, isCorrection: nextConfirmed != confirmed)
        confirmed = nextConfirmed
        return true
    }

    public mutating func finish(_ finalText: String) {
        guard !finalized else { return }
        apply(finalText, confirmedRanges: [NSRange(location: 0, length: finalText.utf16.count)], isCorrection: finalText != text)
        finalized = true
    }

    private mutating func apply(_ next: String, confirmedRanges: [NSRange], isCorrection: Bool) {
        let tokens = Self.tokens(next)
        if isCorrection {
            // Only compare recent context: the speech corrector revises bounded audio windows.
            // This keeps a long dictation from producing quadratic UI work.
            let old = Self.tokens(text).suffix(512).map(\.text)
            let recent = tokens.suffix(512).map(\.text)
            let offset = max(0, tokens.count - recent.count)
            highlighted = []
            if !text.isEmpty {
                for change in recent.difference(from: old) {
                    if case .insert(let index, _, _) = change {
                        let absolute = offset + index
                        if confirmedRanges.contains(where: { NSLocationInRange(tokens[absolute].range.location, $0) }) { highlighted.insert(absolute) }
                    }
                }
            }
            correctionRevision += 1
        }
        var rangeIndex = 0
        runs = tokens.enumerated().map { index, token in
            while rangeIndex < confirmedRanges.count && NSMaxRange(confirmedRanges[rangeIndex]) <= token.range.location { rangeIndex += 1 }
            let isConfirmed = rangeIndex < confirmedRanges.count && NSLocationInRange(token.range.location, confirmedRanges[rangeIndex])
            let changed = isConfirmed && highlighted.contains(index) && !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return Run(text: token.text, tone: changed ? .changed : isConfirmed ? .confirmed : .draft)
        }
        text = next
    }

    private static func tokens(_ text: String) -> [Token] {
        let value = text as NSString
        return tokenizer.matches(in: text, range: NSRange(location: 0, length: value.length)).map {
            Token(text: value.substring(with: $0.range), range: $0.range)
        }
    }
}
