import Foundation

/// Protects document framing without injecting placeholder tokens into MT.
/// Inline URLs, names and numbers remain in their sentence for model context;
/// their fidelity must be checked by qualification, not assumed from this helper.
public enum StructuredTranslation {
    public static func translate(_ text: String, using translate: (String) throws -> String) rethrows -> String {
        var output = ""
        var position = text.startIndex
        var fence: String?
        while position < text.endIndex {
            let end = text[position...].firstIndex(where: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) ?? text.endIndex
            let line = String(text[position..<end])
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                output += line
                if trimmed.hasPrefix(marker) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                output += line
            } else if trimmed.isEmpty || isLiteralLine(trimmed) {
                output += line
            } else {
                let leading = String(line.prefix(while: { $0.isWhitespace }))
                let trailing = String(line.reversed().prefix(while: { $0.isWhitespace }).reversed())
                let body = String(line.dropFirst(leading.count).dropLast(trailing.count))
                let marker = listMarker(body)
                let content = String(body.dropFirst(marker.count))
                output += leading + marker
                output += content.isEmpty || isLiteralLine(content) ? content : try translate(content)
                output += trailing
            }
            guard end < text.endIndex else { break }
            output.append(text[end])
            position = text.index(after: end)
        }
        return output
    }

    private static func listMarker(_ text: String) -> String {
        let pattern = #"^(?:[-+*•]|[0-9]+[.)])\s+(?:\[[ xX]\]\s+)?"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return "" }
        return String(text[range])
    }

    private static func isLiteralLine(_ text: String) -> Bool {
        if text.hasPrefix("`") && text.hasSuffix("`") { return true }
        if !text.contains(where: { $0.isWhitespace }) {
            if text.hasPrefix("https://") || text.hasPrefix("http://") || text.hasPrefix("www.") { return true }
            if text.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil { return true }
        }
        return !text.unicodeScalars.contains(where: CharacterSet.letters.contains)
    }
}
