import Foundation
import CoreGraphics


public struct PhotoTextLine: Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let confidence: Double
    public let bounds: CGRect
    public init(id: UUID = UUID(), text: String, confidence: Double, bounds: CGRect) {
        self.id = id; self.text = text; self.confidence = confidence; self.bounds = bounds
    }
}
public struct PhotoTextBlock: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var source: String
    public var translation: String?
    public let bounds: CGRect
    public let confidence: Double
    public let lineCount: Int
    public var requiresTranslation: Bool { source.contains(where: \.isLetter) }
    public init(id: UUID, source: String, bounds: CGRect, confidence: Double, lineCount: Int = 1) {
        self.id = id; self.source = source; self.bounds = bounds; self.confidence = confidence; self.lineCount = lineCount
    }
}

/// Conservative paragraph grouping: adjacent aligned lines only. Numbers/prices remain separate.
public enum PhotoTextGrouping {
    public static func blocks(from lines: [PhotoTextLine], rightToLeft: Bool = false) -> [PhotoTextBlock] {
        let valid = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.bounds.width > 0 && $0.bounds.height > 0 && !$0.bounds.isNull }
        let sorted = valid.sorted {
            if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY < $1.bounds.minY }
            return rightToLeft ? $0.bounds.maxX > $1.bounds.maxX : $0.bounds.minX < $1.bounds.minX
        }
        var groups: [[PhotoTextLine]] = []
        for line in sorted {
            let candidates = groups.indices.filter { i in
                guard let last = groups[i].last, groups[i].count < 5,
                      last.text.count >= 18, line.text.count >= 12,
                      !(last.text + line.text).contains(where: \.isNumber),
                      groups[i].reduce(0, { $0 + $1.text.count }) + line.text.count < 500 else { return false }
                let a = last.bounds, b = line.bounds, h = max(a.height, b.height)
                let gap = b.minY - a.maxY
                let edge = rightToLeft ? abs(a.maxX - b.maxX) : abs(a.minX - b.minX)
                let overlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
                return gap >= -min(a.height, b.height) * 0.1 && gap <= h * 0.7 && edge <= max(0.012, h * 0.5)
                    && overlap / min(a.width, b.width) > 0.7 && max(a.height, b.height) / min(a.height, b.height) < 1.6
            }
            if let best = candidates.min(by: { line.bounds.minY - groups[$0].last!.bounds.maxY < line.bounds.minY - groups[$1].last!.bounds.maxY }) { groups[best].append(line) }
            else { groups.append([line]) }
        }
        return groups.map { group in
            PhotoTextBlock(id: group[0].id, source: group.map(\.text).joined(separator: " "),
                           bounds: group.dropFirst().reduce(group[0].bounds) { $0.union($1.bounds) },
                           confidence: group.map(\.confidence).min() ?? 0, lineCount: group.count)
        }
    }
}
