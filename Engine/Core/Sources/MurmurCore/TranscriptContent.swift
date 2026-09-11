import Foundation

/// Small, stable text blocks avoid a single enormous text layout for long meetings.
/// Concatenating the blocks reproduces the original text, including whitespace.
public enum TranscriptContent {
    public struct Block: Identifiable, Equatable, Sendable {
        public let id: Int
        public let text: String
    }
    public static func blocks(_ text: String, limit: Int = 700) -> [Block] {
        precondition(limit > 0)
        var result: [Block] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex {
                let searchStart = text.index(start, offsetBy: max(1, limit / 2), limitedBy: end) ?? start
                if let boundary = text[searchStart..<end].lastIndex(where: \.isWhitespace) {
                    end = text.index(after: boundary)
                }
            }
            result.append(Block(id: result.count, text: String(text[start..<end])))
            start = end
        }
        return result
    }
}
