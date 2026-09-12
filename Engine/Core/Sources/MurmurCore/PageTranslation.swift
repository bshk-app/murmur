import Foundation

public struct PageTextRun: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}
public struct PageTextGroup: Codable, Sendable {
    public let id: String
    public let runs: [PageTextRun]
    public init(id: String, runs: [PageTextRun]) { self.id = id; self.runs = runs }
}
public struct PageTranslationRequest: Codable, Sendable {
    public let version: Int
    public let runId: String
    public let title: String
    public let url: String
    public let documentLanguage: String
    public let groups: [PageTextGroup]
    public let truncated: Bool
    public let totalCharacters: Int
    public init(version: Int = 1, runId: String, title: String = "", url: String = "", documentLanguage: String = "", groups: [PageTextGroup], truncated: Bool = false, totalCharacters: Int) {
        self.version = version; self.runId = runId; self.title = title; self.url = url; self.documentLanguage = documentLanguage
        self.groups = groups; self.truncated = truncated; self.totalCharacters = totalCharacters
    }
    public func validate() throws {
        guard version == 1, !runId.isEmpty, runId.utf16.count <= 128, title.utf16.count <= 4096, url.utf16.count <= 16384 else { throw PageTranslationError.invalidPage }
        guard !truncated, groups.count <= 2_000 else { throw PageTranslationError.pageTooLarge }
        let runs = groups.flatMap(\.runs)
        guard runs.count <= 4_000, runs.reduce(0, { $0 + $1.text.utf16.count }) <= 200_000 else { throw PageTranslationError.pageTooLarge }
        guard totalCharacters == runs.reduce(0, { $0 + $1.text.utf16.count }),
              !groups.isEmpty, groups.allSatisfy({ !$0.id.isEmpty && $0.id.utf16.count <= 128 && !$0.runs.isEmpty }), !runs.isEmpty,
              runs.allSatisfy({ !$0.id.isEmpty && $0.id.utf16.count <= 128 }),
              Set(groups.map(\.id)).count == groups.count, Set(runs.map(\.id)).count == runs.count else { throw PageTranslationError.invalidPage }
    }
}
public enum PageTranslationError: Error, Sendable {
    case invalidPage, pageTooLarge, emptyTranslation
}
public struct PageTranslationOutput: Sendable {
    public let translations: [PageTextRun]
    public let fallbackGroups: Int
}
public enum PageTranslationProgress: Sendable {
    case preparing(Double)
    case translating(completed: Int, total: Int)
}

/// Bounded calls permit cancellation between chunks; nothing is published until the whole page succeeds.
public enum PageTranslationProcessor {
    public static func translate(_ page: PageTranslationRequest, from: String, to: String, engine: any TextTranslationEngine,
                                 progress: @escaping @MainActor @Sendable (PageTranslationProgress) -> Void) async throws -> PageTranslationOutput {
        try page.validate()
        do {
            try Task.checkCancellation()
            try await engine.prepare(from: from, to: to) { value in progress(.preparing(value)) }
            var result: [PageTextRun] = [], cache: [String: String] = [:], fallbackGroups = 0, outputCharacters = 0
            for (index, group) in page.groups.enumerated() {
                try Task.checkCancellation()
                await progress(.translating(completed: index, total: page.groups.count))
                let content = group.runs.filter { requiresTranslation($0.text) }
                var grouped: [String]?
                if content.count > 1 {
                    let packed = markedText(content)
                    if content.count <= 12, packed.count <= 800, !content.contains(where: { $0.text.contains("__MM") || $0.text.contains("\n") || $0.text.contains("\r") || $0.text.range(of: #"^\s*(?:[-+*•]|[0-9]+[.)])\s"#, options: .regularExpression) != nil }) {
                        let translated = try await engine.translate(packed, from: from, to: to)
                        try Task.checkCancellation()
                        grouped = unpack(translated, count: content.count)
                    }
                    if grouped == nil { fallbackGroups += 1 }
                }
                var position = 0
                for run in group.runs {
                    let text: String
                    if !requiresTranslation(run.text) { text = run.text }
                    else if let grouped { text = framing(run.text).leading + grouped[position] + framing(run.text).trailing; position += 1 }
                    else if let previous = cache[run.text] { text = previous }
                    else {
                        text = try await translateRun(run.text, from: from, to: to, engine: engine)
                        cache[run.text] = text
                    }
                    outputCharacters += text.utf16.count
                    guard outputCharacters <= 800_000 else { throw PageTranslationError.pageTooLarge }
                    result.append(.init(id: run.id, text: text))
                }
            }
            try Task.checkCancellation()
            await progress(.translating(completed: page.groups.count, total: page.groups.count))
            await engine.unload()
            try Task.checkCancellation()
            return .init(translations: result, fallbackGroups: fallbackGroups)
        } catch { await engine.unload(); throw error }
    }

    static func markedText(_ runs: [PageTextRun]) -> String {
        runs.enumerated().map { "__MM\($0.offset)__ " + $0.element.text }.joined(separator: " ") + " __MM\(runs.count)__"
    }
    static func unpack(_ text: String, count: Int) -> [String]? {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines), pieces: [String] = []
        guard remaining.hasPrefix("__MM0__") else { return nil }
        remaining.removeFirst("__MM0__".count)
        for index in 1...count {
            let marker = "__MM\(index)__"
            guard let range = remaining.range(of: marker) else { return nil }
            let piece = String(remaining[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty, !piece.contains("__MM") else { return nil }
            pieces.append(piece); remaining = String(remaining[range.upperBound...])
        }
        return remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? pieces : nil
    }
    /// Formatting characters (including U+FEFF), separators and numbers carry
    /// no linguistic text by themselves. Preserve them instead of asking a model
    /// to translate a fragment that can legitimately tokenize to empty output.
    private static func requiresTranslation(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }
private static func framing(_ text: String) -> (leading: String, trailing: String) {
    (String(text.prefix(while: { $0.isWhitespace })),
     String(text.reversed().prefix(while: { $0.isWhitespace }).reversed()))
}
    private static func translateRun(_ text: String, from: String, to: String, engine: any TextTranslationEngine) async throws -> String {
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if !requiresTranslation(line) { lines.append(line); continue }
            let frame = framing(line)
            var rest = String(line.dropFirst(frame.leading.count).dropLast(frame.trailing.count))
            var translated: [String] = []
            while !rest.isEmpty {
                try Task.checkCancellation()
                let end = rest.index(rest.startIndex, offsetBy: min(800, rest.count))
                let prefix = rest[..<end]
                let split = end == rest.endIndex ? end : prefix.lastIndex(where: \.isWhitespace).flatMap { $0 > rest.startIndex ? $0 : nil } ?? end
                let piece = String(rest[..<split])
                let output = requiresTranslation(piece) ? try await engine.translate(piece, from: from, to: to) : piece
                try Task.checkCancellation()
                guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PageTranslationError.emptyTranslation }
                translated.append(output.trimmingCharacters(in: .whitespacesAndNewlines))
                rest = String(rest[split...]).trimmingCharacters(in: .whitespaces)
            }
            lines.append(frame.leading + translated.joined(separator: " ") + frame.trailing)
        }
        return lines.joined(separator: "\n")
    }
}
